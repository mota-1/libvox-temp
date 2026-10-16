# Plano de implantação do LibVox

O LibVox é uma assistente de conversa para o catálogo, chamada MARC.IA. O leitor
pergunta em linguagem natural, como por exemplo: *"vocês têm alguma coisa sobre 
xadrez para iniciantes?"*, e recebe os títulos que a biblioteca tem, com quantos 
exemplares estão disponíveis e onde. O usuário acessa o chat na mesma página do 
formulário de busca do catálogo, sem substituir a busca atual.

Nosso objetivo é manter o LibVox como um projeto de extensão permanente do 
IMPA Tech uma vez que o projeto é de código aberto e outras instâncias do mesmo
podem ser criadas para atender outras bibliotecas. Ou ainda, o próprio IMPA 
poderia prover o sistema como um serviço para outras instituições.

## Etapa 1: Ambiente de testes

* Configurar máquina dentro do datacenter do IMPA para prover o modelo "LLM" que interpreta as questões do usuário e indica quais consultas o LibVox deve fazer. O modelo em si não acessa o catálogo. (Analisando com o Daniel e Lucas)
* Criar uma instância do Koha da nossa biblioteca dedicada a testes, com cópia do acervo. (Analisando com Sérgio Piloto)

## Etapa 2: Acesso ao catálogo

* Criar um usuário de API no Koha com **permissão apenas de consulta ao
catálogo**. É o próprio Koha que recusa qualquer outra operação.

* Não há acesso a dados de usuários, empréstimos, reservas ou multas, nem
qualquer função de edição.

* As buscas não chegam ao servidor da biblioteca: o LibVox trabalha sobre uma
cópia do acervo que mantém atualizada. A única consulta em tempo real é a de
disponibilidade de exemplar.

## Etapa 3: Alteração no catálogo

* Acrescentar uma linha ao template da tela de consulta ao acervo, que faz
aparecer um botão no canto da página.

* É a única modificação no Koha. Nenhum registro, configuração ou comportamento
da busca atual é alterado, e quem não clicar no botão usa o catálogo como hoje.

* Reversível removendo a mesma linha.

## Etapa 4: Política de uso

Definir o texto apresentado ao leitor ao clicar no botão, antes da primeira
pergunta. Deve informar:

* **o que é a ferramenta**: uma assistente que responde sobre o acervo desta
  biblioteca;
* **que o acesso é anônimo**: nenhum dado de identificação é coletado, e o
  sistema não tem onde registrar nome, e-mail, telefone ou endereço de rede;
* **que as perguntas e respostas são guardadas por tempo indeterminado**, e com
  quais finalidades: melhoria da ferramenta **e** publicações científicas
  futuras, declaradas separadamente;
* **que o leitor não deve escrever dados pessoais na conversa**: o sistema não
  os coleta, mas o que for digitado fica guardado como parte da pergunta.

## Sequência

1. Máquina do modelo configurada e instância de testes disponível, com o acervo
   carregado
2. Avaliação das respostas e ajustes
3. Redação da política de uso
4. Alteração no template, com a ferramenta ainda desativada
5. Abertura ao público
