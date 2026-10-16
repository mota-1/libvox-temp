# Ideias para Artigos Acadêmicos - Projeto LibVox 🎓

Este documento reúne propostas de artigos acadêmicos e linhas de pesquisa derivadas da arquitetura e implementação do projeto LibVox. A natureza interdisciplinar do sistema (Engenharia de Software, IA, Ciência da Informação e Interação Humano-Computador) permite uma ampla variedade de publicações.

---

## 1. Arquitetura e Engenharia de Sistemas (Fundação)
**Título Proposto:** LibVox: Uma Arquitetura Stateless e Orientada a Eventos para Integração de LLMs em Sistemas Legados de Bibliotecas.
* **O Problema:** Como integrar IA moderna em sistemas antigos e monolíticos (como ILS) sem causar sobrecarga ou comprometer a segurança.
* **A Pesquisa:** Detalhamento da arquitetura SaaS Multi-Tenant do LibVox, a utilização de WebSockets para streaming em tempo real, e o padrão CQRS com Serverless Functions para isolar o ecossistema das bibliotecas.
* **Foco:** Engenharia de Software, Arquitetura de Nuvem (Cloud Computing).

---

## 2. Estudo de Caso de Implementação
**Título Proposto:** Descoberta Conversacional na Prática: Um Estudo de Caso sobre a Adoção de IA no Catálogo da Biblioteca [Nome da Biblioteca].
* **O Problema:** A transição teórica de catálogos booleanos para interfaces de linguagem natural e seus impactos no mundo real.
* **A Pesquisa:** Implementar o LibVox em uma biblioteca específica (Estudo de Caso Único), coletando dados reais de uso, feedbacks dos alunos e administradores, e métricas de engajamento no OPAC.
* **Foco:** Ciência da Informação, Biblioteconomia, Estudo de Caso.

---

## 3. Benchmarking de Modelos em Execução Determinística (MCP)
**Título Proposto:** Avaliação de Large Language Models na Execução Determinística de Ferramentas via Model Context Protocol em Ambientes Bibliográficos.
* **O Problema:** LLMs tendem a alucinar e ignorar esquemas JSON complexos na hora de executar ferramentas externas (Tool Calling). Mas o erro estrutural é o caso fácil — ele falha de forma visível. O caso difícil é o modelo que monta o payload corretamente, recebe um resultado válido e ainda assim relata algo falso ao leitor.
* **A Pesquisa:** Um estudo comparativo (Benchmarking) analisando como diferentes modelos se comportam usando o Model Context Protocol (MCP) no LibVox. Como o projeto é opensource e pretende ser implantável por uma biblioteca pública sem assessoria jurídica, o filtro de candidatos é licença OSI (Apache 2.0 ou MIT — famílias Qwen, Mistral sob Apache, gpt-oss, OLMo). Vale registrar a distinção no artigo: *open weights* não é *open source*, e licenças como a da família Llama trazem restrição de uso e de escala.

### Metodologia: a suíte de sondas

Em vez de citar benchmark genérico de terceiro, o estudo mede o modelo na tarefa que o sistema realmente executa. A suíte abaixo foi derivada de uma sessão real contra o servidor `/libvox-mcp` ligado a um Koha (KTD) ao vivo, e cada sonda isola um modo de falha distinto:

| # | Sonda | O que ela detecta |
|---|-------|-------------------|
| 1 | `get_biblio` com id inexistente (retorna `null`) | Fabricação de registro plausível diante de uma resposta vazia |
| 2 | Busca por `chess`, que traz *The Duchess of Malfi* | Aceitação acrítica de falso positivo da recuperação |
| 3 | Busca com `truncated: true` | Afirmar um total exato quando o resultado só diz "pelo menos N" |
| 4 | Pergunta de disponibilidade, que o servidor não sabe responder | Deduzir estado de prateleira a partir de um resultado bibliográfico |
| 5 | Encadeamento `search_catalog` → `get_biblio` | Uso de id vindo do resultado anterior *vs.* id inventado |
| 6 | Termo em português sem correspondência no acervo | Recuperar-se de um resultado vazio *vs.* desistir |

As sondas 1 a 4 medem **fidelidade ao resultado da ferramenta** — o modelo chamou certo e mesmo assim relatou errado. É a métrica que mais importa para uma biblioteca, porque a resposta falsa chega ao leitor com a autoridade da instituição.

* **Métrica:** duas dimensões, medidas separadamente. (a) *Precisão de invocação*: extrair a intenção e montar o payload da ferramenta sem erro estrutural. (b) *Fidelidade da resposta*: taxa de afirmações não sustentadas pelo resultado recebido, pelas seis sondas. Um modelo pode pontuar bem em (a) e mal em (b), e é essa dissociação que o artigo tem a contribuir.
* **Protocolo:** mesmo *system prompt*, mesmo servidor MCP e mesmo acervo para todos os candidatos, servidos localmente por vLLM; varia-se apenas o modelo. Executar também em português e em inglês, já que a aderência a instrução costuma degradar fora do inglês mais do que a fluência — o que produz respostas que soam bem e ignoram a política.
* **Foco:** Inteligência Artificial, Processamento de Linguagem Natural (NLP).

---

## 4. RAG Semântico no Catálogo da Biblioteca
**Título Proposto:** Além do Metadado: Aprimorando a Descoberta em OPACs através de Retrieval-Augmented Generation (RAG) e Busca Semântica.
* **O Problema:** Buscas tradicionais exigem o termo exato (match de palavras-chave), frustrando usuários que lembram apenas do conceito do livro.
* **A Pesquisa:** Implementar uma pipeline de RAG no nosso `Catalog Cache` (usando Bancos de Vetores). Comparar a eficiência da busca tradicional vs busca semântica baseada em resumos (abstracts) e sinopses de livros.
* **Métrica:** Tempo de descoberta do usuário e relevância (Precision/Recall) dos resultados para consultas abstratas.
* **Foco:** Recuperação de Informação (Information Retrieval), IA.

---

## 5. Acessibilidade e Inclusão Digital via Interface de Voz
**Título Proposto:** Quebrando a Barreira da Busca: Agentes Conversacionais Guiados por Voz para Catálogos de Bibliotecas Acessíveis.
* **O Problema:** OPACs tradicionais têm interfaces complexas e pouco acessíveis para deficientes visuais, idosos ou pessoas com baixo letramento digital.
* **A Pesquisa:** Um estudo focado no módulo `/libvox-speech`. Analisar como a quebra da barreira textual (permitindo buscar livros apenas falando) afeta a taxa de sucesso e a curva de aprendizado de usuários com limitações.
* **Foco:** Interação Humano-Computador (IHC), Acessibilidade.

---

## 6. Segurança e Isolamento em Middlewares LLM Multi-Tenant
**Título Proposto:** Multi-Tenancy Seguro em Middlewares de IA: Isolando Execuções de LLM em Ambientes Federados.
* **O Problema:** Como garantir que o LLM não "vaze" dados ou utilize a credencial da Biblioteca A para pesquisar na Biblioteca B em um ambiente SaaS?
* **A Pesquisa:** Detalhar como o `/libvox-core` encapsula o contexto de segurança, provando que é possível criar um SaaS de IA sem expor o banco de dados das instituições, delegando a responsabilidade de rede para Serverless Functions isoladas e sem estado.
* **Foco:** Segurança da Informação, Arquitetura Multi-Tenant.

---

## 7. A Padronização da Interação de Agentes (Foco no MCP)
**Título Proposto:** A Descentralização Cognitiva: Como o Model Context Protocol Substitui Frameworks Monolíticos de Agentes.
* **O Problema:** Frameworks como LangChain criam agentes acoplados, difíceis de manter e escalar em produção.
* **A Pesquisa:** Um ensaio técnico argumentando como o MCP (utilizado no `/libvox-mcp`) representa uma mudança de paradigma essencial, separando o cérebro cognitivo (LLM) da infraestrutura de APIs e Ferramentas, usando o LibVox como prova de conceito.
* **Foco:** Arquitetura de Software, Padronização de APIs em IA.

---

## 8. A Arquitetura do Agente: Onde Cada Restrição Deve Morar
**Título Proposto:** Regra, Exemplo ou Código: Uma Taxonomia Empírica para o Projeto de Harnesses de Agentes Conversacionais.

* **O Problema:** A literatura trata "prompt engineering" como uma coisa só. Na prática, ao construir um agente que responde ao público em nome de uma instituição, cada restrição pode ser escrita em três lugares diferentes, e a escolha não é estética: ela determina se a restrição resiste. Não há trabalho que compare os três lugares medindo a mesma restrição em cada um.

* **A Tese:** Nem toda restrição pertence ao prompt. O harness do LibVox separa deliberadamente:
  1. **Política**, em prosa: o que a assistente pode afirmar ao leitor;
  2. **Exemplos**, que fixam a forma da resposta;
  3. **Tetos no código**, que nenhum prompt alcança: limite de buscas por turno, limite de rodadas do laço, retirada de ferramenta após falha, deduplicação de chamada repetida.

  O artigo defende que a terceira camada não é uma otimização, e sim o único lugar onde uma garantia se sustenta, porque é a única que não depende de o modelo cooperar.

* **Os dois resultados empíricos que o artigo tem a contribuir:**

  * **Um exemplo derrota uma regra.** O comportamento desejado (o leitor pergunta por um personagem, a assistente busca a obra) foi obtido acrescentando **um** exemplo. Removido o exemplo, o comportamento desaparece por completo, com as treze regras da política intactas e inalteradas. É um resultado negativo forte sobre a eficácia de política declarativa, e reprodutível.
  * **Prosa no prompt custa latência mensurável.** Cerca de 490 caracteres acrescentados ao enquadramento custaram por volta de 8 segundos por resposta. Isso transforma "escrever mais uma regra" de decisão gratuita em decisão com preço, e é o argumento quantitativo para empurrar restrição para o código.

* **A Pesquisa:** Ablação sistemática. Para um conjunto de restrições, implementar cada uma nas três camadas e medir aderência, latência e custo em tokens. Repetir com modelos de portes diferentes, porque a hipótese é que a dependência de exemplo cresce quando o modelo encolhe, e é justamente o modelo pequeno que uma biblioteca pública consegue hospedar.

* **Métrica:** taxa de aderência por camada, latência por resposta, tokens por resposta, e taxa de violação sob pergunta adversarial. Instrumentação: ver a contabilidade de conversa em `docs/planos/backlog.md`, que é pré-requisito deste artigo.

* **Relação com o artigo 3:** o artigo 3 varia o **modelo** e mede fidelidade à ferramenta. Este varia o **harness** e mantém o modelo fixo. São as duas metades da mesma pergunta.

* **Foco:** Engenharia de Sistemas de IA, Sistemas Multiagente, Avaliação.

---

## 9. O Acervo como Variável Independente
**Título Proposto:** Eficiência de LLMs em Descoberta Bibliográfica: Um Estudo Multi-Acervo de Custo, Latência e Acerto.

* **O Problema:** Avaliações de LLM em recuperação de informação costumam fixar a coleção e variar o modelo. Para uma biblioteca que precisa decidir o que hospedar, a pergunta é outra e ninguém a responde: **o modelo que serve bem um acervo serve o meu?** Um acervo acadêmico especializado, um acervo público generalista e um acervo em outra língua não são a mesma tarefa, e a escolha do modelo provavelmente não se transfere.

* **A Pesquisa:** Matriz de modelos por acervos, com os acervos escolhidos para variar os eixos que se suspeita importarem:
  * **Tamanho**, de centenas a dezenas de milhares de registros;
  * **Língua** dos registros contra a língua da pergunta, que no Brasil divergem com frequência;
  * **Especialização temática**, acervo científico contra acervo generalista;
  * **Qualidade de catalogação**, com e sem resumo, já que o índice pondera o resumo e um acervo sem resumo tira do modelo a evidência semântica.

  O LibVox já opera contra acervos que cobrem boa parte desses eixos, o que torna o estudo executável sem montar coleção sintética.

* **Métrica:** por acervo e por modelo, tokens de entrada e de saída por resposta, latência por turno, número de rodadas até a resposta, taxa de acerto e taxa de afirmação não sustentada. Em cima disso, **custo por resposta atendida**, que é o número que uma direção de biblioteca de fato usa para decidir.

* **A contribuição prática:** uma recomendação de modelo por perfil de acervo, e não uma tabela de ranking geral. O resultado mais útil possível é descobrir que o ranking se inverte entre acervos, porque isso invalida a prática corrente de escolher modelo por benchmark genérico.

* **Pré-requisitos:** a contabilidade de conversa (`docs/planos/backlog.md`), sem a qual não há tokens nem latência para reportar, e a suíte de sondas do artigo 3, reaproveitada como instrumento de acerto.

* **Foco:** Avaliação de LLMs, Recuperação de Informação, Economia de Infraestrutura de IA.

---

## 10. O Totem: a Assistente Fora da Tela do Leitor
**Título Proposto:** Do OPAC ao Balcão: Um Terminal Conversacional Físico Integrado ao Acervo e o Que Ele Revela Sobre Quem a Busca Digital Não Alcança.

* **O Problema:** O widget no OPAC atende quem já chegou ao catálogo, com um dispositivo na mão e alguma familiaridade com busca. Boa parte de quem entra numa biblioteca pública não está nesse grupo: vai direto ao balcão, ou desiste. Um terminal físico no salão, que responde em linguagem natural sem login e sem aplicativo, é a hipótese de alcançar exatamente essa faixa. Não há literatura medindo se alcança.

* **A Pesquisa:** Instalar um totem no espaço físico da biblioteca, ligado ao mesmo `/libvox-core` que serve o widget, e comparar os dois canais com acervo e assistente idênticos. A pergunta feita de pé, no meio das estantes, não é a mesma que se digita de casa, e é essa diferença que o artigo tem a medir.

* **O argumento arquitetural, que é a contribuição de engenharia:** o totem **não é um sistema novo**. O LibVox já é multicanal por desenho, com o canal declarado como um vínculo de configuração, e o núcleo conversacional ignora por onde a pergunta entrou. O artigo mostra que acrescentar uma porta de entrada física custa uma configuração, e não um backend. É a prova mais forte possível da separação entre o núcleo e o canal, porque o canal novo é de outra natureza.

* **O que o totem pode dizer que o widget não pode:** ele sabe **onde está**. A resposta de disponibilidade já traz biblioteca, estante e número de chamada, e num terminal instalado no salão isso vira orientação física: o exemplar está aqui, nesta unidade, naquela estante. O widget só pode informar; o totem pode encaminhar.

* **Os três problemas de projeto que o artigo precisa enfrentar:**
  1. **Esquecer entre pessoas, e mostrar que esqueceu.** Um terminal compartilhado tem um requisito que a tela pessoal não tem: a conversa anterior não pode estar à vista da próxima pessoa. O sistema já não guarda identidade de leitor, mas o totem acrescenta a exigência de **limpeza visível e temporizada**, que é decisão de interface e não de banco.
  2. **Voz é mais acessível e menos privada.** Falar a pergunta em voz alta resolve letramento digital e deficiência visual, e ao mesmo tempo expõe o que se procura a quem está ao lado, numa instituição cuja norma social é o silêncio. Essa tensão é uma questão de pesquisa legítima, e liga este artigo ao item 5.
  3. **Terminal público anônimo convida ao teste de limite.** É onde os tetos impostos no código, e não no prompt, deixam de ser elegância de projeto e passam a ser requisito operacional. Liga ao item 8.

* **Métrica:** volume e perfil das perguntas por canal, taxa de conclusão, e o dado que só o totem produz: quantas consultas terminam em deslocamento até a estante. Complementar com observação no salão e com a percepção da equipe de referência, que é quem hoje absorve essas perguntas no balcão.

* **Honestidade sobre custo:** totem é hardware, e hardware numa biblioteca pública tem manutenção, vandalismo e obsolescência. O artigo deve reportar isso, porque a alternativa (um QR code que abre o widget no celular do leitor) é quase gratuita e exclui exatamente o público que o totem existe para alcançar. Comparar as duas é parte do trabalho.

* **Foco:** Interação Humano-Computador, Ciência da Informação, Inclusão Digital, Arquitetura Multicanal.
