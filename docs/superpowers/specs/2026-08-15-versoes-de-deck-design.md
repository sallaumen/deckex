# Versões de deck — design

**Data:** 2026-08-15
**Estado:** aprovado pelo dono na conversa; implementação em PRs sequenciais.

## O problema

Hoje cada otimização aplicada vira um **deck novo** — "Iroh das Lontra —
otimizado", "… — otimizado, etapa 5". Depois de três rodadas a mesa tem cinco
decks que são o mesmo deck em momentos diferentes, sem nada dizendo qual veio de
qual, o que mudou entre eles, nem como voltar.

O dono descreveu o que quer: *"cada versão que vamos aplicando deveria ser um
versionamento do mesmo deck, cada aplicação fica claro o que foi feito na
versão, e temos uma tela para acompanhar o histórico, mudar para alguma versão
específica se quiser, comparar versões (quais cartas eu tenho que comprar tendo
a versão 1.0 em comparação com a 1.10)"*.

## O modelo

Um deck tem **um estado de trabalho** e **uma linha de versões**.

O estado de trabalho continua sendo `deck_cards` — é o que toda lente mede, o
que a página edita, o que o otimizador copia. Nada nesse caminho muda, e essa é
a razão da escolha: reescrever `deck_cards` como "linhas da versão atual"
tocaria em cada consulta do app para comprar um problema que uma foto resolve.

Uma **versão é uma fotografia** desse estado num instante, com a história de
como chegou nele:

| Campo | O quê |
|---|---|
| `number` | sequencial por deck: v1, v2, v3 |
| `origin` | `:import`, `:manual` ou `:optimization` |
| `optimization_id` | a rodada que produziu, quando houver |
| `list` | a lista principal como `[%{"name", "quantity"}]` |
| `commanders` | os nomes, fora da lista, como o sandbox já faz |
| `changes` | o que esta versão fez em relação à anterior |
| `label` | uma linha do dono, ou derivada da origem |

`list` é jsonb e não linhas: uma versão é histórico, nunca é medida por lente
nenhuma, e é exatamente a forma que o sandbox do otimizador já usa. Duas
representações da mesma coisa foi como o texto da decklist acabou certo num
lugar e errado no outro.

## O que cria uma versão

- **O import**, sempre: v1 é o deck como ele chegou.
- **Aplicar uma otimização**, com as mudanças da rodada em `changes` e o
  `optimization_id` apontando para a origem.
- **O dono**, explicitamente, quando quiser marcar onde está.

Editar carta a carta **não** cria versão. Cem edições manuais viram cem versões
que ninguém lê; o estado de trabalho absorve as edições e o dono marca a versão
quando ela significa alguma coisa. A tela mostra quando o trabalho divergiu da
última versão, para que "não salvei" nunca seja uma surpresa.

## Voltar para uma versão

Restaurar reescreve `deck_cards` a partir da foto, dentro de uma transação. As
cartas já estão no catálogo — uma versão só existe porque aquelas cartas já
foram resolvidas um dia — então restaurar **não fala com a Scryfall**.

Restaurar não apaga nada: a linha continua, e voltar para a v2 estando na v5
deixa as v3, v4 e v5 exatamente onde estavam. Se depois disso o dono marcar uma
versão nova, ela é a v6 — a história é um registro do que aconteceu, não uma
árvore que se poda.

## Comparar duas versões

O diff entre duas fotos, nos dois sentidos, com preço:

- **entram** — o que a versão de destino tem e a de origem não: a lista de
  compra para sair de uma e chegar na outra;
- **saem** — o contrário, que não custa dinheiro e por isso não entra no total.

Carta sem preço conhecido aparece e fica fora do total, como em todo lugar.

## Fora de escopo (por ora)

- Ramificar: uma versão gera outra linha. A duplicação de deck já cobre o caso
  de "quero testar outro caminho sem perder este".
- Numeração semântica (1.0 / 1.10). Sequencial inteiro é inequívoco; se o dono
  quiser marcos maiores depois, é um campo a mais e nenhuma mudança de modelo.
