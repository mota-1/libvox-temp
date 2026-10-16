# Backlog

Ideias aceitas que ainda não viraram trabalho. Cada uma diz o que é, por que
vale, e as armadilhas já identificadas, para quem pegar não redescobrir.

Não é lista de desejos: o que está aqui foi decidido que se faz, falta quando.

---

## Cache de `search_catalog`, chaveado pelos argumentos da ferramenta

**A ideia, na forma decidida.** Cachear **apenas o `search_catalog`**, e chavear
pelos **argumentos que a LLM decidiu**, não pelo que o leitor escreveu. Mesma
geração do acervo mais mesmos argumentos significa mesmas linhas, e isso é
determinístico.

Fica **dentro** da função de busca, e não ao lado dela, para que não haja como
chamar a busca sem passar pelo cache. O projeto já usa esse argumento em outro
lugar: o `redacted()` do driver tem escrito que a regra é mais fácil de manter
quando existe exatamente uma função para procurar.

**Por que chavear pelos argumentos, e não pela pergunta.** O argumento de
ferramenta já é o contexto da conversa resolvido. O leitor escreve "e o segundo
volume?", a LLM lê o histórico e produz uma consulta concreta. Chavear ali mata
o problema do contexto em vez de contorná-lo, e dispensa normalizar linguagem
natural: o que se compara é um objeto pequeno e estruturado.

**Por que a voz não sofre.** Só a busca é cacheada. O modelo continua sendo
chamado para redigir, continua dizendo o que procurou e por que não achou. Não
existe resposta enlatada.

### Onde exatamente

`libvox-core/src/libvox_core/routes.py` expõe `/internal/v1/search_catalog` e
delega para `index_search`, que é `libvox-sync/src/libvox_sync/search.py`, função
`search`. É dentro dela que o cache entra, porque é o ponto por onde todo mundo
passa.

### Quanto isso economiza, de verdade

**Não é uma rodada de LLM.** O modelo já decidiu buscar, então o turno já pagou
uma chamada, e vai pagar outra para redigir a resposta. O que se economiza é:

1. **A chamada de embedding**, em `search.py`, onde `embedder.embed_query(query)`
   faz uma ida de rede ao serviço de LLM. **Este é o custo dominante** e a razão
   principal para fazer o cache.
2. A consulta ao índice, que é local e barata.

Vale fazer, mas a expectativa precisa ser essa, e não "a LLM é consultada menos
vezes".

### A condição de correção, que é uma só

**Isto só é determinístico enquanto uma geração publicada for imutável.** Não é
o argumento fixo que garante o resultado, é o acervo não mudar por baixo dele.
O Índice de Descoberta trabalha por gerações: `discovery_tenant.active_generation`
aponta para a viva, e uma importação completa escreve uma geração nova e troca o
ponteiro numa linha só (`libvox-sync/src/libvox_sync/pipeline.py`, `_next_generation`
e `_publish`). Enquanto for assim, uma entrada carimbada com a geração em que
nasceu expira sozinha.

**Consequência para trabalho futuro, que precisa ficar escrita:** se o sync
incremental um dia alterar a geração viva no lugar, em vez de publicar uma nova,
este cache passa a servir dado velho **em silêncio**. Ou o incremental também
troca a geração, ou ele invalida o cache explicitamente. Quem for mexer no sync
incremental precisa ler este parágrafo antes.

### Detalhes de implementação já decididos

* **A chave é `(tenant, geração, hash dos argumentos)`.** O tenant não é
  opcional: cache compartilhado entre bibliotecas vazaria o que os leitores de
  uma perguntaram para a outra.
* **Serialização canônica dos argumentos.** `{"query": "x", "limit": 5}` e
  `{"limit": 5, "query": "x"}` têm que produzir a mesma chave: ordenar as
  chaves, e preencher os valores padrão **antes** de hashear, para que argumento
  ausente e argumento no padrão não virem duas entradas.
* **Onde guardar.** Tabela no banco do índice, e não dicionário em memória: ela
  sobrevive ao restart, é compartilhada entre réplicas, e ganha a limpeza de
  graça, porque `_drop_inactive_generations` já sabe descartar geração velha.
* **Acerto e erro têm o mesmo risco**, que é nenhum, pela mesma razão: dentro de
  uma geração o índice não muda. Não há motivo para cachear só a busca vazia.

### O que NÃO entra

**`check_availability` não entra no cache. Nunca.** É estado de circulação ao
vivo. Cachear disponibilidade reintroduz exatamente a falha que
`libvox-core/src/libvox_core/availability.py` foi escrito para impedir: dizer a
um leitor que o exemplar está na estante quando ele saiu emprestado hoje de
manhã.

### Um complemento independente

O **cache do embedding** continua valendo por si, e é ainda mais simples: a
chave é `(modelo de embedding, texto)`, sem geração, porque um embedding não
muda quando o acervo muda. Se for feito junto, boa parte do ganho descrito acima
já vem dele.

### Como saber se valeu

Depende da contabilidade, abaixo. Sem medir chamadas, tokens e tempo antes, não
há como afirmar que o cache melhorou alguma coisa.

---

## Contabilidade da conversa

**O que existe hoje: nada.** O `libvox-core/src/libvox_core/agent/llm.py` lê
`body["choices"][0]["message"]` e **descarta `body["usage"]` inteiro**; o
`Completion` carrega só `text` e `intents`. Não há nenhuma medição de tempo no
pacote `agent/`.

**O que justifica.** O comentário de `libvox-core/migrations/001_conversations.sql`
já diz que o log de conversas é durável para que o estudo de
`docs/ideias_artigos_academicos.md` tenha transcrições. Uma transcrição sem
custo e sem tempo responde o que ela disse, não quanto custou dizer.

### Duas unidades, não uma

Uma pergunta do leitor são várias chamadas ao modelo, e misturar as duas perde
o que se quer saber.

*Por chamada ao modelo:* modelo efetivamente servido (o gateway roteia, e o nome
configurado pode não ser o atendido), tokens de entrada e de saída, latência,
número da rodada, e se foi rodada de ferramenta ou resposta final.

*Por turno, que é o que o leitor sentiu:* tempo da pergunta até a resposta,
quantas rodadas, quais ferramentas, se bateu em algum teto (`DEFAULT_MAX_ROUNDS`,
`SEARCHES_PER_TURN`, retirada de `AVAILABILITY`), e o desfecho.

Medir a latência das ferramentas **em separado** importa: `search_catalog` bate
no índice local e `check_availability` bate no servidor da biblioteca. São
ordens de grandeza diferentes.

### Desenho

Tabela nova, pendurada em `conversation_id`, **não** colunas novas em
`messages`. Uma mensagem é o que foi dito; uma métrica é como foi produzida, e
os ciclos de vida são diferentes. RLS pela mesma subconsulta de `messages`, sem
`tenant_id` duplicado. E a regra de `001_conversations.sql` vale igual: nenhuma
coluna que identifique pessoa.

### Três armadilhas

1. Guardar o bloco `usage` cru em `jsonb`, além das colunas contadas.
   Provedores acrescentam campos, e a migração
   `003_what_the_provider_attached.sql` já decidiu essa questão uma vez: guardar
   intacto em vez de adivinhar colunas.
2. `usage` **falta** em alguns provedores e em streaming. Registrar tem que ser
   best-effort e fora do caminho crítico: uma resposta a um leitor nunca pode
   falhar porque a métrica não pôde ser gravada.
3. Guardar **tokens, não dinheiro**. Preço muda e é por provedor; virar dinheiro
   é trabalho de relatório, com tabela de preços datada, não de coluna.

### Quem lê

Painel do operador e o artigo. Atenção ao mesmo tropeço de `channel_bindings`:
o `BindTenantScope` só vale no painel da biblioteca, então um operador não
enxerga tabela com RLS por tenant. O caminho de leitura do lado do operador
precisa ser resolvido junto, não depois.

---

## Manual da bibliotecária e manual do operador

**A ideia.** Dois manuais, em português, um para cada painel. O `/app` é da
bibliotecária, o `/admin` é do operador. São públicos diferentes, com poderes
diferentes e medos diferentes, e o produto já os separa: os documentos só
espelham isso.

**Não juntar os dois num documento só.** A tentação é óbvia e o resultado é o
manual que ninguém lê, porque metade dele não se aplica a quem está lendo.

### O manual da bibliotecária

A espinha já existe: é o `docs/plano_de_implantacao.md` mais o fluxo de conexão
do catálogo. A sequência que ela percorre:

1. conectar o catálogo: URL, identificador e segredo;
2. testar a conexão;
3. rodar a primeira carga do acervo;
4. escolher nome e cor da assistente;
5. copiar a linha do widget para o template do OPAC.

**A página mais valiosa do manual é a do botão de testar conexão**, e ela
precisa ser escrita à mão. O `libvox-core/src/libvox_core/ils.py` devolve um
código por tipo de falha justamente porque cada um manda a bibliotecária para um
lugar diferente, e a mensagem do driver atravessa literalmente até ela. Essa
tradução de código para frase em português não existe em lugar nenhum hoje:

* `not_configured`: ainda não há conexão salva;
* `no_driver`: o LibVox não fala com esse sistema;
* `unauthorized` e `token_refused`: a credencial foi recusada, e os dois têm
  causas diferentes, sendo que `token_refused` costuma ser configuração do
  servidor Koha e não erro de quem digitou;
* `permission_denied`: a credencial está certa e falta uma permissão, e o Koha
  diz qual;
* `upstream_unavailable`: o endereço não respondeu.

**Duas restrições de escrita, que decidem o tom:**

1. **Quem lê não é quem instalou.** O manual não pode supor acesso a terminal,
   a servidor ou a linha de comando. Tudo o que ele manda fazer tem que ser
   possível pelo `/app`.
2. **Sem jargão de dentro.** Nada de *tenant*, *RLS*, *endpoint*, *driver*. Se
   um conceito não tem nome em português de biblioteca, o manual inventa uma
   frase, não importa o termo.

### O manual do operador

Cobre criar uma biblioteca, subir os módulos, acompanhar a sincronização e ler
log. Fonte principal: `deploy/README.md` e os `README.md` dos módulos, que já
existem em inglês e aqui viram procedimento.

**A armadilha específica deste manual**, e a razão de ela estar escrita aqui: o
`BindTenantScope` vale apenas no painel da biblioteca, então **o operador não
enxerga os vínculos de canal**. Um manual que mandar o operador "conferir o
widget no /admin" está mandando procurar uma tela vazia, e quem seguir vai
concluir que a configuração sumiu. Conferir isso antes de escrever, e não
depois de alguém perder uma tarde.

Vale também um bloco de **o que não fazer**, curto, com as coisas que destroem
dado e não têm volta. O `deploy/up.sh` já carrega uma delas por escrito: nunca
derrubar os containers com remoção de volume.

### Decisões de forma

* **Poucas capturas de tela.** Painel Filament muda de aparência com frequência,
  e manual com captura velha perde credibilidade mais rápido do que manual sem
  captura nenhuma. Onde a captura for indispensável, registrar em que versão foi
  feita.
* **Ficam em `docs/`**, em português, como o resto dos guias. Os `README.md` dos
  módulos continuam em inglês e continuam sendo para quem programa.

---

## O nome do autor sai na forma invertida da catalogação

**O que se vê.** Numa conversa real contra o Koha Demo, a MARC.IA respondeu:

> Você perguntou pela Capitu e procurei por "Dom Casmurro". **Dom Casmurro**, de
> Assis, Machado de, tem 1 exemplar disponível, na biblioteca Centerville.

O "de Assis, Machado de" não é erro do modelo. Ele escreveu a preposição natural
do português (*"Dom Casmurro, **de** …"*) e emendou o nome como recebeu, que já
vinha invertido pela convenção de catalogação. As duas coisas certas somadas dão
uma frase errada. A captura está em
`palestras/libvox-ibict/imgs/chast.png`, no slide 4 da apresentação ao IBICT.

**De onde vem.** `libvox-driver-koha/src/libvox_driver_koha/normalize.py`, em
`author=clean_text(raw.get("author"))`. O `clean_text` apara pontuação ISBD e
aspas; ele nunca reordena, e não deveria mesmo. O Koha devolve a forma
catalogada, e invertida é o normal dela.

### Onde NÃO consertar: no dado armazenado

A tentação é desinverter na normalização e gravar "Machado de Assis". **Não
resolve nada e custa fidelidade ao catálogo**, porque a busca já é imune à
ordem das palavras, por dois caminhos independentes:

* o `tsvector` de `migrations/005_search_without_accents.sql` indexa o autor com
  peso `B`, e lexema não tem ordem: `Assis, Machado de` e `Machado de Assis`
  geram o mesmo conjunto;
* o filtro por autor em `libvox-sync/src/libvox_sync/search.py`,
  `_text_conditions`, casa **uma palavra por vez** com `ILIKE`. O comentário lá
  já registrou o porquê, e ele fecha esta questão: *"Catalogues record `Fecho,
  Bob.` and readers ask for `bob fecho` … Inverted is the normal form of a
  catalogued name, not an edge case."*

Ou seja: mudar o que se grava não melhora a recuperação e ainda afasta o índice
da forma que a bibliotecária reconhece.

### Onde consertar: no que chega ao modelo

O resultado da ferramenta é JSON, e quem redige a frase é a LLM. Então só há
dois lugares:

1. **Um campo a mais no registro devolvido**, do tipo `author_display`, ao lado
   do `author` catalogado. A lista de colunas devolvidas está em `search.py`
   (`biblio_id`, `title`, `author`, `isbn`, `publisher`, `copyright_date`,
   `item_type`, `series`). O `author` continua sendo o que se indexa e o que se
   filtra; o novo é só para ser dito em voz alta.
2. **Instruir o modelo a desinverter**, na descrição da ferramenta ou no prompt.

**A 1 é a que combina com o resto do projeto.** A 2 depende de o modelo lembrar,
a cada resposta, de uma regra de formatação, e é justamente o tipo de garantia
que este código prefere tirar do modelo e pôr na estrutura. Vale lembrar que o
alvo de implantação são modelos abertos pequenos, que é onde instrução de
formatação se perde primeiro.

### As armadilhas de desinverter

Não é trocar o que está antes e depois da vírgula. O que já se sabe:

* **Partículas.** `Assis, Machado de` vira `Machado de Assis`, e a partícula
  muda de lado. Vale para `de`, `da`, `dos`, `van`, `von`, `del`.
* **Datas coladas no nome.** `Machado de Assis, 1839-1908` é comum em MARC, e o
  que vem depois da última vírgula não é nome.
* **Autor corporativo.** `Instituto Brasileiro de Informação em Ciência e
  Tecnologia` não tem inversão nenhuma para desfazer, e mexer nele estraga.
* **Nome já direto.** Parte do acervo vem sem inversão, e aplicar a regra duas
  vezes desfaz o acerto.
* **Mais de um autor** num campo só, separados por `;`.

**Regra de ouro sugerida:** na dúvida, não mexer. Nome dito na forma catalogada
soa formal; nome embaralhado por uma regra afobada soa errado, e numa biblioteca
é a instituição que fica malvista.

### Como saber que funcionou

O acervo de testes já tem os casos: `Machado de Assis` (partícula), `Fecho, Bob`
(simples) e os corporativos. Um teste de tabela com essas entradas, mais uma
entrada já direta e uma corporativa, cobre tudo o que está listado acima.

---

## Feito: o domínio passou a ser `libvox.com.br`

Concluído em 23 de setembro de 2026. Os dois hosts escolhidos mantêm o arranjo
antigo, trocando apenas o domínio de base:

| Host | O que serve |
| :--- | :--- |
| `libvox.com.br` | a página pública em `/`, e os painéis em `/app` e `/admin` |
| `marcia.libvox.com.br` | o widget |

`app.libvox.com.br` e `admin.libvox.com.br` foram considerados e descartados: os
dois painéis do Filament são distinguidos **por caminho**, então um host por
painel daria `app.libvox.com.br/app`, e o Laravel tem um `APP_URL` só, o que
jogaria quem entrasse por um host para o outro no meio do fluxo de login.

**O que continua valendo, e é a parte que ainda pode morder:** o `<script>` já
colado em um OPAC aponta para `marcia.battisti.com.br`, e o IBICT recebeu os
endereços antigos antes da reunião de 29 de setembro. O host antigo precisa
seguir respondendo, ou redirecionando, até que ambos sejam atualizados.

E a lição que vale para a próxima troca de domínio: **o `allowed_origins` lista a
origem da página, não a do script.** A página mudou de `battisti.com.br/libvox`
para `libvox.com.br`, então é essa origem que o vínculo de canal precisa ter. A
comparação é exata, sem curinga, e origem ausente recusa a sessão com um sintoma
que não se parece com erro de domínio: o widget abre e não conversa.
