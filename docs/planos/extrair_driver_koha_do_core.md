# Plano: tirar o driver Koha de dentro do processo do Core

## Contexto

Hoje o `libvox-driver-koha` é uma biblioteca Python instalada dentro da imagem do
`libvox-core`. O Core importa `KohaDriver` e fala com o Koha da biblioteca a
partir do próprio processo. Isso foi uma simplificação, e o destino declarado do
driver é ser um componente serverless.

A boa notícia é que a costura já existe e já está documentada: `handler.py:1-35`
define `handle(request) -> response`, em JSON, e diz textualmente que é "o ponto
entre a versão em container e a serverless". O contrato já carrega o segredo no
corpo (`connection`), já tem lista branca de chaves (`handler.py:159`), já tem
`redacted()` para log (`handler.py:167`) e já tem 14 testes. Não é um desenho
novo, é a ativação de um desenho que está escrito.

O que este plano faz: coloca um servidor HTTP fino sobre `handle()`, sobe um
container `driver-koha`, e troca os dois pontos de chamada do Core por chamadas
remotas.

## Decisão de escopo: só o Core sai, o resto fica

**`libvox-core` passa a chamar por HTTP.** São dois pontos, ambos já com import
adiado dentro da função, ou seja, duas edições locais:
`availability.py:77` e `ils.py:42`.

**`libvox-sync` continua importando em processo.** O motivo é medível: uma
importação completa de 8.774 registros são 90 requisições ao servidor da
biblioteca, com **um único token OAuth** reaproveitado por todas as páginas e com
o ritmo adaptativo entre elas (`client.py:180-210`, intervalo
`max(0.2, custo_anterior * 0.5)`). Se cada página virasse uma invocação remota, o
token teria que ser comprado de novo a cada página, dobrando a conta para ~180
requisições, e o ritmo seria perdido, justamente o mecanismo que existe porque um
servidor caiu quando as páginas foram em sequência. O sync já é o seu próprio
container; o driver morar dentro dele não é o problema descrito.

**`libvox-mcp/direct_koha.py` continua na dependência opcional.** É o backend
experimental, marcado no próprio módulo como algo que não deve ir para produção,
e seus 24 testes dependem de `isinstance` das classes de exceção do driver.
Continua instalado pelo extra `koha`, como hoje.

Consequência: o `libvox-driver-koha` deixa de ser dependência do **Core** apenas.
Continua sendo dependência do sync e do extra do MCP.

## A mudança de contrato que realmente importa

Hoje o `availability.py:124-128` constrói **um** driver e percorre a lista de ids
no mesmo objeto. O custo real no servidor da biblioteca, para 5 ids:
1 token + 5 chamadas de itens + 1 de bibliotecas + 1 de localizações = **8
requisições**.

Se o Core fizer 5 invocações remotas, cada uma constrói o seu próprio
`KohaDriver` (e tem que construir: `handler.py:16-19` e o teste
`test_nothing_is_held_between_invocations` garantem que nada sobrevive à
invocação, que é o que impede o token da biblioteca A de sair na requisição da
biblioteca B). Seriam 5 tokens + 5 itens + 5 bibliotecas + 5 localizações =
**até 20 requisições** para o mesmo resultado.

Por isso o leque de ids passa para dentro do driver:

* `check_availability` aceita **`biblio_ids`** (lista) além do `biblio_id` atual,
  e o laço roda dentro de um único `with KohaDriver(...)`. Carga no Koha idêntica
  à de hoje, e a invariante "nada é guardado entre invocações" continua
  verdadeira, porque o driver continua nascendo e morrendo dentro de um `handle()`.
* O driver **não decide** o que fazer com falha parcial. Retorna
  `{"records": [...], "failed": [{"biblio_id": n, "code": "..."}]}`, e a regra de
  que qualquer falha reprova a chamada inteira continua no Core
  (`availability.py:164-173`), que é onde ela está escrita e testada.

## Ação nova: `fetch_page`

O `ils/check` sonda com `driver.fetch_page(None)` e `page_size=1`
(`ils.py:67-74`), e `fetch_page` não existe em `_ACTIONS`
(`handler.py:130-134`). Precisa ser acrescentada, junto com a única peça de
serialização que falta no `contract.py`: **`Page.as_dict()`**, incluindo
`next_cursor` e `skipped`. `BiblioRecord`, `SearchResult` e `Availability` já
têm.

Isso também é o que destrava mover o sync um dia, sem movê-lo agora.

## O servidor

Módulo novo no driver, `src/libvox_driver_koha/server.py`: FastAPI, **uma** rota.

* `POST /invoke`: corpo é exatamente o envelope de `handle()`, resposta é
  exatamente o envelope de `handle()`. **Sempre HTTP 200 quando `handle()`
  retorna**, inclusive em falha, porque `handler.py:32-34` já decidiu que falha é
  dado e não exceção. Código não 200 fica reservado para transporte e
  autenticação.
* `GET /healthz`: sem token, só prova que o processo está de pé.
* Autenticação: cabeçalho `x-libvox-service-token`, copiando
  `libvox-core/src/libvox_core/app.py:75-92`, inclusive a recusa na partida
  quando `LIBVOX_ENV != "development"` (`config.py:230-241`).
* Todo log de requisição passa por `redacted()`. É a regra que já está escrita em
  `handler.py:167-180` e em `libvox-driver-koha/AGENTS.md:29`.
* `fastapi` e `uvicorn` entram como **extra opcional** `server` no
  `pyproject.toml`, não como dependência base, para que a imagem do sync não
  cresça. Mesmo padrão do extra `koha` do `libvox-mcp`.

**O que muda de verdade em exposição, dito sem rodeio:** hoje não existe salto de
rede entre descriptografar e usar o segredo; `fetch()` retorna e o valor vira
argumento três linhas depois. Depois desta mudança o segredo em claro atravessa
uma fronteira de container. As contenções são: a rede `libvox_internal` é
privada, a porta no host é `127.0.0.1` apenas, o token protege a rota, e
`redacted()` é obrigatório. A alternativa (dar `LIBVOX_CRYPTO_KEY` e acesso ao
banco de tenants ao driver) foi descartada porque contraria a invariante escrita
em `handler.py:10-14`: o driver não sabe qual biblioteca está servindo.

## O cliente, dentro do Core

Módulo novo `libvox-core/src/libvox_core/driver_client.py`, com uma função
`invoke(action, params, connection) -> dict`.

* Em `ok: false`, levanta `DriverFailure(RuntimeError)` com `.code`, `.message` e
  `.details`. Não reimporta as classes do driver: `errors.py:8-9` já declara que
  **o `code` é o contrato** e que ele atravessa como texto. `ils.py:82` usa
  `exc.code` e `exc.message`, `availability.py:140` usa `exc.code`; os dois
  continuam iguais na forma.
* Falha de transporte (container fora do ar, timeout) vira
  `DriverFailure(code="driver_unreachable")`, **não** uma exceção solta. Sem
  isso, ela cai no `except Exception` de `ils.py:83-89`, que reporta
  `problem="unexpected"` com `str(exc)` cru no painel da bibliotecária, o que
  colocaria a URL interna do driver na tela dela.
* Configuração: `LIBVOX_DRIVER_TIMEOUT_S` e **um mapa**, não uma URL. Ver a
  seção "O segundo driver" logo abaixo, que é o motivo de ser um mapa.

## O segundo driver

O objetivo declarado do container separado é que um dia exista um driver para
outro ILS. Vale medir o que isso custa hoje e o que este plano faz com esse
custo, porque uma das decisões só é barata se for tomada agora.

**Hoje**, acrescentar `pergamum` toca sete lugares em quatro módulos:

| Onde | O quê |
| :--- | :--- |
| `libvox-sync/migrations/002_tenant_ils_credentials.sql:33` e `libvox-portal/database/migrations/2026_08_27_025000_create_tenant_ils_table.php:45` | o mesmo `CHECK (ils_type IN ('koha'))`, em dois bancos |
| `libvox-portal/app/Enums/IlsType.php:15` | o enum que alimenta o select da bibliotecária |
| `libvox-sync/src/libvox_sync/__main__.py:111,129,623` | `DRIVERS`, `BY_ILS_TYPE` e `choices=["koha"]` |
| `libvox-core/src/libvox_core/ils.py:60` e `availability.py:116` | dois `!= "koha"` escritos à mão |
| Dockerfiles do Core e do sync, `.dockerignore`, os dois `pyproject.toml` e `requirements.txt`, `ci.yml` | o pacote novo tem que entrar em cada imagem que o importa |

E há a dívida de fundo: o protocolo `Driver` e os tipos (`BiblioRecord`, `Page`,
`Availability`, `errors.py`) moram **dentro do pacote do Koha**, então um driver
Pergamum precisaria importar `libvox_driver_koha` para dizer o que é um registro.
O `drivers/__init__.py:9-11` já registra isso, e nomeia a saída: um
`libvox-common`.

**Depois deste plano**, a conta se parte em duas, e a diferença é grande.

*Caminho vivo (disponibilidade e teste de conexão), que é o que sai do Core:*
vira **configuração, sem código**. Para isso o Core resolve `ils_type → URL` por
variável de ambiente, por convenção de nome:

```
LIBVOX_DRIVER_URL_KOHA=http://driver-koha:8094
LIBVOX_DRIVER_URL_PERGAMUM=http://driver-pergamum:8095
```

e os dois `!= "koha"` somem. "Não há driver para este ILS" passa a significar
"nenhuma URL registrada para este tipo", que é um fato de implantação e não um
literal no código. Um segundo driver no caminho vivo é então: um container novo,
uma variável, nenhuma edição em `libvox-core`, nenhuma dependência Python,
nenhuma mudança de Dockerfile. **É este o ganho real de tirar o driver de dentro
do Core**, e ele só existe se a resolução for por mapa. Com URL singular o
segundo ILS ficaria mais caro do que hoje, não mais barato.

O `POST /invoke` ajuda de outra forma: congela o contrato **em JSON**, que é
neutro de linguagem. Um driver Pergamum não precisa ser Python.

*Caminho de carga (sync):* continua custando o que custa hoje, pacote Python,
dependência, Dockerfile e CI, porque o sync fica em processo por decisão deste
plano. É aqui que o `libvox-common` acabará sendo necessário, e o
`drivers/__init__.py` continua sendo a única edição quando esse dia chegar.

*Inevitável nos dois cenários:* o `CHECK` nas duas migrações e o enum do portal.
É o portal que oferece a lista à bibliotecária, e essa lista é uma decisão de
produto, não de arquitetura.

### A escada de timeouts ganha um degrau

A ordem está escrita em cinco lugares e testada em
`libvox-core/tests/test_config.py:86`. Passa a ser:

`driver interno 30s < Core → driver 45s < MCP → Core 60s < Core → MCP 90s`

O teste importa hoje `libvox_driver_koha.client.DEFAULT_TIMEOUT_S` na linha 109.
Como o Core deixa de depender do pacote, o teste passa a ancorar em
`settings.driver_timeout_s`, e o 30s do driver fica afirmado na suíte do próprio
driver.

Uma consequência de comportamento que vale registrar: com a ação em lote, a
espera do Core por disponibilidade passa a ser **um** corte em 45s, onde hoje são
até 5 esperas de 30s em sequência. Uma biblioteca genuinamente lenta passa a
falhar mais cedo. Isso é melhora, mas é mudança.

## Implantação

Segundo serviço no `libvox-driver-koha/docker-compose.yml`, ao lado do `driver`
de uma tacada só, compartilhando a mesma linha `image:`. É exatamente o arranjo
`sync`/`worker` do `libvox-sync/docker-compose.yml:22,96`, e o comentário daquele
arquivo já explica por que o nome da imagem é compartilhado.

* Serviço **`driver-koha`**, não `driver-koha`. O nome do serviço é o DNS na rede,
  como `core` e `mcp`, e pela seção anterior o próximo driver vira
  `driver-pergamum` ao lado. Um nome genérico serviria ao primeiro e atrapalharia
  o segundo.
* `ports: - "127.0.0.1:8094:8094"`. 8094 porque 8090 é o painel, 8091 a API
  interna, 8092 o widget, 8093 o `demo/serve.py`, e 8080/8081 são o OPAC e o
  staff do Koha Testing Docker. O motivo de ser só loopback é mais forte aqui do
  que em 8091 ou 8000: esta porta recebe credencial de ILS descriptografada no
  corpo.
* `networks: [default, libvox_internal]`, `libvox_internal` como `external: true`.
* `restart: unless-stopped`.
* No `Dockerfile`: `EXPOSE 8094` e `ENV LIBVOX_DRIVER_HOST=0.0.0.0`, com a mesma
  divisão explicada em `libvox-core/Dockerfile:28-32`. Instalar com o extra
  `[server]`. O usuário não root continua sendo `driver`.
* `libvox-driver-koha/driver.sh`, copiado de `libvox-mcp/mcp.sh`: `up|start`,
  `check`, `logs`, `down|stop`, com `check_token`, `check_network`, build e
  recreate sempre, e o `curl` esperando **401** como prova barata de que está
  servindo e não apenas vivo.
* `deploy/up.sh`: `libvox-driver-koha` já está em `MODULES` (linha 39). Falta um
  `agree` do token em `check_shared_secrets` (linhas 183-201) e um `step` em
  `cmd_up` **antes** do `./core.sh` e depois do `libvox-db`, com o inverso em
  `cmd_down`.
* `deploy/versions.env:4-6` diz "as cinco linhas `image:`"; já são seis e passam a
  sete. Corrigir na mesma mudança.

## Testes

**Novos, no driver:**
* `tests/test_server.py`: 401 sem token; envelope de sucesso atravessa intacto;
  falha volta como 200 com `ok: false`; nenhum log carrega `client_secret`.
* Em `test_handler.py`: ação `fetch_page`, `Page.as_dict()`, e o lote, este
  último afirmando contra o `FakeKoha` do `conftest.py:71-155` que **cinco ids
  custaram um único POST de token**. É este teste que trava o ganho.

**Reescritos, no Core:** os quatro de `test_endpoints.py` (`:87`, `:136`, `:268`,
`:300`) e os seis de `test_ils_check.py` deixam de remendar a classe
`KohaDriver` e passam a remendar `driver_client.invoke` (ou um transporte
simulado). O de regra 5, `test_an_id_absent_from_the_index_never_reaches_the_ils`,
fica **mais forte**: passa a poder afirmar que nenhuma chamada HTTP saiu.

**Intactos:** os 105 testes do driver e os do sync, porque nada do caminho em
processo muda.

## Ordem de execução

1. **Driver, só adições:** `Page.as_dict()`, ação `fetch_page`, `biblio_ids` em
   `check_availability`. Ninguém quebra, nada é chamado ainda.
2. **Driver, o container:** `server.py`, extra `server`, Dockerfile,
   docker-compose, `.env.example`, `driver.sh`. Sobe e fica ocioso.
3. **Core, a troca:** `driver_client.py`, `ils.py`, `availability.py`, config,
   remoção da dependência em `pyproject.toml:43`, `requirements.txt:25` e
   `Dockerfile:9,11`. Este é o corte.
4. **Volta:** `deploy/up.sh`, `.github/workflows/ci.yml:96`, READMEs, a escada de
   timeouts nos cinco lugares, e o `docs/diagramas-components.drawio`, onde o
   driver passa a ser um componente implantável com interface própria.

Não haverá chave de retorno para o caminho em processo. Um interruptor que mantém
os dois vivos é exatamente o "caminho paralelo que apenas se parece com o real"
contra o qual o `__main__.py:1-11` do próprio driver adverte.

## Verificação ponta a ponta

```
cd libvox-driver-koha && pytest                  # 105 + os novos
./driver.sh up && ./driver.sh check              # 401 sem token, healthz de pé
cd ../libvox-core && pytest                      # inclui os dez reescritos
./core.sh up
```

Depois, contra a `lib-ibict` e a `lib-local`, que já estão configuradas:

* Botão "testar conexão" no painel da bibliotecária: precisa continuar
  distinguindo `unauthorized`, `permission_denied` e `upstream_unavailable`, que
  é o valor inteiro do botão.
* `./core.sh ask lib-ibict "vocês têm Dom Casmurro?"`: a resposta tem que trazer
  exemplares disponíveis, ou seja, `check_availability` atravessou o salto.
* Com o `driver-koha` parado de propósito: a pergunta tem que dar a frase de
  catálogo indisponível, e não uma resposta confiante de que a biblioteca não tem
  o livro. É a falha que toda esta arquitetura existe para evitar.
* `./core.sh bench`, para confirmar que o salto não mudou o tempo de resposta de
  forma perceptível.

## O que este plano não faz

* Não move o `libvox-sync` para trás do HTTP.
* Não mexe no `direct_koha.py` do MCP.
* Não cria o `libvox-common` nem escreve um segundo driver. Apenas deixa de
  cobrar edição de código no Core quando ele existir.
* Não implementa a contabilidade da conversa, que virou item de
  `docs/planos/backlog.md`.
* Não muda o `MAX_AVAILABILITY_IDS = 5` nem a regra 5.
* Não implanta serverless. Prepara o terreno: depois disto, trocar o container
  por uma função é substituir `server.py` pelo adaptador da plataforma, que é o
  que `handler.py` sempre prometeu.
