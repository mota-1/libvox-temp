# Plano — o lado de escrita do `/libvox-sync`

> **Executado em 2026-08-27.** Este arquivo é o plano como foi aprovado, com um
> registro do que de fato entrou. Ele fica aqui porque as decisões valem mais
> que o plano: conforme cada uma prova seu valor, o texto migra para o README do
> módulo, que é onde este projeto guarda razões. O que sobrar aqui é história.

## O que entrou

| Passo | Commit | |
| :--- | :--- | :--- |
| Fundir o driver duplicado | `a93c89d` | ✅ |
| Conexão entregue sem transação aberta | `3b0779c` | ✅ — não estava no plano; sem isso a carga em lotes não commitava |
| Pipeline: geração nova, publicação atômica | `15dd1ae` | ✅ |
| Testes do Tenant DB no banco de teste | `cb5eb40` | ✅ — não estava no plano; ver "O que deu errado" |
| Lista de bibliotecas vinda do registro | `f7555b0` | ✅ |
| Comando `full` | `c70fb91` | ✅ |
| Documentação | `fdf22dd` | ✅ |
| Chave de criptografia no container | `8a8c3dd` | ✅ — defeito encontrado depois, no que já tinha sido entregue |

Estado ao fim: `/libvox-sync` 63 testes, `/libvox-driver-koha` 57, `/libvox-mcp` 38,
`/libvox-portal` 193. Milestones 3 e 4 de 6 fechados.

## O que o plano previu errado

Três suposições minhas que o banco desmentiu, e que estão no código com o
motivo junto:

- **`COPY` é impossível sob RLS.** `COPY FROM not supported with row-level
  security` — recusa categórica, com `INSERT` na dica. O plano dizia "a
  propriedade a testar, não presumir", e foi por isso que o teste veio antes.
- **Todo `tenant_scope` era um savepoint.** `SET statement_timeout` abre
  transação, então a conexão era entregue já dentro de uma. Nada seria durável
  até a conexão fechar.
- **O `--limit` no `full` publicaria um índice truncado como `ready`.** Foi
  removido: é a mentira confiante que o projeto inteiro existe para evitar.

E duas coisas que o plano não previu e que a execução obrigou:

- **Um registro pode chegar duas vezes.** O Koha pagina por offset, então um
  catálogo editado durante a caminhada repete linhas. Sem `ON CONFLICT DO
  NOTHING`, a hora três de uma importação morre por chave primária.
- **A suíte destruía o banco de desenvolvimento.** Ver abaixo.

## O que deu errado

`test_credentials.py` truncava `tenant_ils` no banco de **desenvolvimento**, não
num banco de teste — então toda execução de `pytest` apagava silenciosamente as
credenciais armazenadas. Meu teste de registro piorou isso com um `TRUNCATE
tenants CASCADE`, que levou junto o cadastro inteiro do portal: bibliotecas,
widget keys e channel bindings.

As credenciais não voltam. São ciphertext e não existe caminho de leitura em
lugar nenhum do sistema, por desenho — que é a propriedade certa, e é também o
que torna a perda definitiva.

Corrigido em `cb5eb40`: as duas suítes usam `libvox_tenant_test`, que o
`docker/initdb/02-test-database.sql` do portal já criava exatamente para isso.

---

## Contexto, como estava antes

*Daqui em diante o texto é o plano aprovado, palavra por palavra e no presente
de quem ainda não tinha executado nada. Foi deixado assim de propósito: um plano
reescrito depois do fato perde justamente o que ele errou.*

O `/libvox-sync` estava no **milestone 2 de 6**, e o que falta é exatamente o que a
pergunta pede. O módulo tem 793 linhas e **nenhum estágio de carga**: não existe um
`INSERT INTO discovery_biblio` em lugar nenhum do repositório. O `extract` normaliza,
imprime uma tabela e termina com `"Nothing was written."`

O schema, esse, está inteiro e há meses: gerações na PK, `discovery_active` com
`security_invoker`, tsvector português ponderado A/B/C, RLS forçada, e um índice
`(tenant_id, generation, ils_timestamp)` cujo comentário diz *"Supports the incremental
sync's 'what changed since?' probe."* As duas metades — extração e índice — nunca se
encontraram. O README do módulo diz isso com todas as letras.

O que o cadastro de bibliotecas muda não é o pipeline; é **de onde vem a lista de
trabalhos** e **quem pode perguntar**. Hoje o `tenant list` precisa de conexão de
superusuário porque lê `tenant_ils`, que tem RLS. A tabela `tenants`, criada pelo portal,
**não tem RLS**, o `libvox_app` tem DML nela, e `ils_configured_at` responde "quem já
configurou o catálogo" sem tocar na tabela de credenciais. O caminho normal de operação
deixa de usar superusuário.

Resultado pretendido: `python -m libvox_sync full --all` enumera as bibliotecas
cadastradas, importa o catálogo de cada uma numa geração nova, vira o ponteiro
atômicamente, e deixa `index_status` no vocabulário que o `/libvox-mcp` publica para o
modelo.

---

## 1. O que existe, o que falta

| | Estado |
| :--- | :--- |
| Schema do Discovery Index | ✅ completo, migrado, testado |
| Driver Koha (extrair + normalizar) | ✅ completo — **duplicado em dois módulos** |
| Escrita em `discovery_biblio` | ❌ não existe |
| Alocação/troca/descarte de geração | ❌ não existe |
| Escrita em `discovery_tenant` | ❌ nada escreve `index_status`, `active_generation`, `last_sync_at`, `last_error` |
| Enumerar bibliotecas | ⚠️ só via `list_tenants` sobre `tenant_ils`, com superusuário |
| Despacho por `ils_type` | ⚠️ `if credentials.ils_type != "koha"` no meio do CLI |
| Consumo de `tenant_events` | ❌ `consumed_at` nunca foi escrito por nada |
| Trava de execução concorrente | ❌ não existe |
| Retry, backoff, log estruturado | ❌ não existe |

---

## 2. Colapsar a duplicação do driver — primeiro, e por quê

`libvox-sync/src/libvox_sync/drivers/koha.py` são 272 linhas quase idênticas ao
`/libvox-driver-koha`, comentários verbatim inclusive. `libvox-sync/pyproject.toml` não
depende do driver. E o README do driver **afirma uma dependência que não existe**:

> *"`/libvox-sync` imports this package; the dependency runs one way. Koha knowledge used
> to live inside the ETL worker, which meant the live path would have had to reimplement
> it — two definitions of what a title is, drifting."*

Os dois normalizadores concordam hoje. A deriva que o README descreve é estruturalmente
possível agora, e o pipeline é código novo: escrevê-lo contra o contrato canônico custa
menos do que escrevê-lo contra o fork e migrar depois.

- `pyproject.toml` ganha `libvox-driver-koha` (editable, como o README raiz já instrui).
- Apagar `src/libvox_sync/records.py` e `src/libvox_sync/drivers/koha.py`.
- `drivers/__init__.py` deixa de definir `Page`/`Driver`/`iter_records` e passa a
  reexportar de `libvox_driver_koha.contract`.
- `drivers/fixture.py` **fica** — é o que permite testar o pipeline sem rede — e passa a
  importar `normalize_page` do driver.
- O README do driver deixa de mentir.

O pipeline **não usa `iter_records`**: ele precisa do laço de páginas para lotear a
escrita e para somar `page.skipped`, que `iter_records` descarta hoje. Nenhuma mudança na
API pública do driver.

---

## 3. `pipeline.py` — a importação completa

```python
@dataclass(frozen=True, slots=True)
class ImportResult:
    tenant_id: str
    generation: int
    written: int
    skipped: int
    pages: int

def full_import(discovery, tenant_id, driver, *, batch_size=500,
                allow_empty=False) -> ImportResult
```

### A sequência

1. **Trava.** `pg_try_advisory_lock(hashtext('libvox_sync:' || tenant_id))` na conexão do
   Discovery Index, **em escopo de sessão**, não de transação. Falsa → `SyncAlreadyRunning`
   e saída limpa. É a trava de execução e o que evita duas gerações com o mesmo número.
   (Colisão de `hashtext` entre dois tenants serializa sem corromper; anotar.)
2. **Garantir a linha.** `INSERT INTO discovery_tenant (tenant_id) VALUES (%s)
   ON CONFLICT DO NOTHING` — dentro de escopo, porque o `WITH CHECK` exige.
3. **Coletar lixo.** `DELETE FROM discovery_biblio WHERE generation IS DISTINCT FROM
   active_generation` — limpa geração órfã de uma execução que morreu no meio.
4. **Alocar.** `COALESCE(MAX(generation), 0) + 1`, depois da coleta.
5. **Carregar por página.** Cada lote em sua própria transação com escopo. Isso é seguro
   **porque a geração nova é invisível** — `discovery_active` só junta a ativa. Evita uma
   transação gigante segurando a conexão durante um acervo inteiro.
6. **Trocar.** Uma transação curta: `UPDATE discovery_tenant SET active_generation = N,
   index_status = 'ready', last_sync_at = now(), last_error = NULL`, e então
   `DELETE FROM discovery_biblio WHERE generation <> N`.
7. **Soltar a trava.**

### As transições de status — a armadilha

`index_status` é contrato com `libvox_mcp.models.IndexStatus`, e o vocabulário é fechado:
`ready | building | stale`. O modelo usa isso para decidir se um resultado vazio significa
*"nada encontrado"* ou *"ainda não indexei"*.

**Um re-import não pode passar por `building`.** Uma biblioteca já `ready` tem uma geração
perfeitamente boa servindo enquanto a nova é escrita; marcá-la `building` faria a MARC.IA
dizer "ainda estou indexando" com o índice funcionando.

| Situação | Antes | Sucesso | Falha |
| :--- | :--- | :--- | :--- |
| Primeira importação | `building` | `ready` | `building` + `last_error` |
| Re-importação | `ready` (inalterado durante) | `ready` | `stale` + `last_error` |

`stale` é a resposta certa para o re-import que falhou: há registros servindo, e eles são
sabidamente velhos. Nenhum valor novo no enum, nenhuma mudança cross-module.

### Duas recusas

**Catálogo vazio não vira índice pronto.** Zero registros extraídos é quase sempre uma
credencial sem a flag `catalogue`, não uma biblioteca sem acervo — e o modo de falha é a
MARC.IA afirmar que a biblioteca não tem nada. Sem `--allow-empty`, `written == 0` não
troca a geração; registra `last_error` e sai diferente de zero.

**`last_error` é higienizado.** É coluna lida pelo `status`, e a mensagem de uma exceção
`httpx` carrega a URL. Truncar, e nunca interpolar o objeto de credencial. O
`ILSCredentials.__repr__` já redige; a regra é não contornar isso.

### A escrita do lote

`COPY discovery_biblio (tenant_id, generation, biblio_id, title, author, isbn, publisher,
copyright_date, item_type, ils_timestamp) FROM STDIN` — `search` é `GENERATED` e não pode
ser fornecida; `synced_at` tem default.

**A propriedade a testar, não presumir:** que a RLS se aplica ao `COPY FROM`. O teste
`a full import cannot write into another tenant's generation` falha alto se não se aplicar,
e aí o fallback é `executemany`.

---

## 4. `registry.py` — de onde vem a lista de trabalhos

```python
@dataclass(frozen=True, slots=True)
class TenantRef:
    tenant_id: str
    display_name: str
    status: str

def syncable_tenants(tenant_conn) -> list[TenantRef]
```

```sql
SELECT tenant_id, display_name, status
  FROM tenants
 WHERE ils_configured_at IS NOT NULL
   AND status <> 'suspended'
 ORDER BY tenant_id
```

Sem escopo e **sem DSN de administrador** — `tenants` não tem RLS e o `libvox_app` tem
`SELECT`. Essa é a mudança concreta que o cadastro traz.

**`provisioning` entra.** Uma biblioteca precisa estar indexada *antes* de poder atender,
e exigir que o operador vire para `active` primeiro cria um ovo-e-galinha: `active` com
índice vazio é pior do que `provisioning` sendo indexada, porque `index_status='building'`
já é a forma correta de dizer "ainda não". `suspended` fica de fora.

Com isso, `cmd_tenant_list` se reescreve sobre `syncable_tenants` mais um escopo por
biblioteca, e **`tenant_admin_dsn` sai do `Settings`** — uma DSN de superusuário a menos
no ambiente.

---

## 5. Despacho por `ils_type`

O `if credentials.ils_type != "koha"` sai do meio do CLI e vira registro:

```python
BY_ILS_TYPE: dict[str, Callable[[ILSCredentials, int], Driver]] = {
    "koha": _koha_driver,
}
```

Casa com o CHECK `ils_type IN ('koha')` do portal. Acrescentar `folio` aqui antes de haver
driver FOLIO cria uma biblioteca configurável que nunca sincroniza — o mesmo argumento que
já está escrito sobre o `DRIVERS` do `--ils`.

---

## 6. CLI

```
python -m libvox_sync full --tenant lib-furg
python -m libvox_sync full --all
python -m libvox_sync full --tenant lib-furg --ils fixture --fixture tests/koha_example.json
```

`--all` enumera pelo registro, importa uma biblioteca por vez, e **uma falha não derruba
as outras**: registra, segue, e o código de saída conta quantas falharam. `--page-size`,
`--batch-size`, `--allow-empty`, `--limit` (para provar o caminho contra um acervo grande
sem esperar por ele).

O `full` deixa de ser "deliberadamente ausente" e o docstring do `__main__` perde essa
frase.

---

## 7. Documentação

- `libvox-sync/README.md`: milestones 3 e 4 ✅; a tabela de transições de status; a recusa
  do catálogo vazio; a trava por advisory lock; o registro como fonte dos trabalhos; e
  `tenant_admin_dsn` saindo.
- **Corrigir `--tenant furg` para `lib-furg`** em todos os exemplos — o CHECK
  `'^lib-[a-z0-9]…'` da `tenants` e a FK de `tenant_ils` agora rejeitam a forma antiga.
- `libvox-driver-koha/README.md`: a afirmação sobre o `/libvox-sync` importar o pacote
  passa a ser verdadeira.
- README raiz: `/libvox-sync` de 🔨 com "extraction is next" para o que estiver de fato
  pronto.

---

## 8. O que fica de fora, e por quê

**Sincronização incremental.** Bloqueada a montante, e verificada — não presumida:
`q={"timestamp":{">":…}}` responde **HTTP 500** na API REST do Koha, enquanto o mesmo
operador em outros campos funciona. Está escrito em três READMEs. O caminho apontado é
OAI-PMH, que tem a vantagem adicional de reportar exclusões, coisa que um filtro por
timestamp nunca faria. O full com troca de geração já dá exclusão correta por construção,
então o incremental é otimização de custo, não de correção.

**O consumidor de `tenant_events`.** A tabela existe, com `pg_notify('libvox_tenant_events', …)`
e `consumed_at` como ack, e continua sem consumidor depois desta rodada. A tabela
*"Standalone (now) / Worker (later)"* do README diz que o que muda é o trigger, com o
pipeline *"identical"* — então o pipeline vem primeiro e é provado one-shot. Quem agenda,
por enquanto, é cron ou systemd timer, e o intervalo mora lá.

**O caminho da credencial continua sendo o do sync.** O README avisa quatro vezes que
`/libvox-core` deve ser o único componente que decifra segredo de biblioteca. Core não
existe, e a alternativa purista — só `--ils` com credencial do ambiente — inviabiliza o
`--all`, que é o ponto inteiro desta rodada. O `full` decifra, e o README diz isso em voz
alta em vez de deixar virar arquitetura por inércia.

**Empacotar o driver como serverless.** O `_ACTIONS` do `handler.py` tem só `get_biblio` e
`search_by_title` — o caminho bulk não tem rota pelo contrato de invocação. E o
`KohaClient` documenta que o import em massa segura um cliente por centenas de requisições
e paga um token só; um `fetch_page` serverless significaria um handshake OAuth2 por
página, contra o servidor de terceiros que a arquitetura existe para poupar.

---

## 9. Ordem de execução

Cada passo termina em commit, prefixo minúsculo e imperativo.

1. `refactor: make libvox-sync import the koha driver instead of copying it`
2. `feat: write extracted records into a new generation`
3. `feat: swap the active generation atomically`
4. `feat: refuse to publish an empty catalog as a ready index`
5. `feat: take the list of libraries from the registry`
6. `feat: add the full command`
7. `docs: document the pipeline, generations and the status transitions`

O consumidor de evento é a rodada seguinte:
`feat: react to a tenant change instead of polling for one`.

---

## 10. Verificação

Tudo já está de pé nesta máquina: KTD em 8080/8081, Discovery Index em 5433, Tenant DB em
5434, portal em 8090.

```bash
# a biblioteca é cadastrada e credenciada pelo painel, não pela linha de comando
#   http://localhost:8090/admin/tenants   -> lib-furg
#   http://localhost:8090/app             -> credenciais do ILS

cd libvox-sync
export LIBVOX_CRYPTO_KEY=...          # o MESMO valor do portal
python -m libvox_sync migrate
python -m libvox_sync full --tenant lib-furg
python -m libvox_sync status --tenant lib-furg
#   status: ready · generation: 1 · records: 436

# a busca que o milestone 6 vai embrulhar
psql "$LIBVOX_DB_DSN" -c "begin; select set_config('libvox.tenant_id','lib-furg',true);
  select biblio_id, title from discovery_active
   where search @@ plainto_tsquery('portuguese','xadrez')
   order by ts_rank(search, plainto_tsquery('portuguese','xadrez')) desc limit 5; commit;"

# a segunda importação supersede a primeira
python -m libvox_sync full --tenant lib-furg
python -m libvox_sync status --tenant lib-furg      # generation: 2, mesma contagem

# e o registro dirige o trabalho
python -m libvox_sync full --all
```

`tests/test_pipeline.py`, Postgres real, `skipif` quando não responde — a convenção de
`test_schema.py`. Nomes como frase, como no resto do módulo:

- `a full import makes records searchable`
- `the previous generation answers until the swap`
- `a second import supersedes the first and drops the old generation`
- `a failed re-import leaves the tenant stale, not building`
- `a failed first import leaves the tenant building, not ready`
- `a full import cannot write into another tenant's generation`
- `an empty extraction does not become a ready empty index`
- `a second import of the same library refuses while one is running`
- `an orphan generation from a crashed run is cleaned up by the next`
- `the registry lists configured libraries and skips suspended ones`
- `the registry does not need a privileged connection`
