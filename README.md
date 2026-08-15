# deckex

Análise de decks de Commander (EDH). Você importa a lista, o app mede a forma do
deck — curva, mana, interação, consistência — e leva esses números pra uma IA com
busca na web, que sugere o que cortar e o que colocar.

O app **não** decide se uma carta é boa. Ele mede o *seu* deck e deixa a parte de
opinião pra IA, que conhece o pool de cartas inteiro. É de propósito: mapear as
~30 mil cartas de Magic já foi feito, e feito melhor, em outros lugares.

## O que ele faz

**Mede o deck.** Curva, base de mana (fontes por cor contra os pips que o deck
exige, fetchlands resolvidas), interação separada entre counters e remoção real,
e consistência. Papéis de carta saem do texto do oracle, com evidência: cada
classificação diz por que foi feita.

**Diz em que Bracket você está.** O piso oficial de Commander Brackets, contado
das regras: Game Changers (lidos da Scryfall, nunca escritos aqui), negação de
terreno em massa e turno extra. O motor reporta um **piso**, nunca um veredito —
as duas perguntas que ele não consegue responder (tem combo de duas cartas? em
que turno o deck fecha?) viram uma pergunta para a IA.

**Escreve um dossiê do deck.** Um "scout" lê a lista uma vez e escreve o plano,
as sinergias, as linhas de vitória e as fraquezas que número nenhum vê. O dossiê
entra em toda consulta seguinte, e toda resposta abre com a leitura do próprio
modelo — instruída a discordar do dossiê em voz alta quando a lista disser outra
coisa.

**Mede o que a mesa sente, e onde o deck morre.** Duas lentes que não são sobre
poder. *Tempo de mesa* conta as cartas que tiram turnos, ações ou destravamento
dos outros três jogadores — turno extra, stax, taxação, roubo, sacrifício
forçado. *Fragilidade* pergunta como o deck perde: quanto dele está no campo
quando cai uma varredura (e se a sua mana está lá junto), quanto depende do
cemitério, e quantos corpos estão de fato **livres** para bloquear — porque uma
criatura que carrega o motor do deck não é um bloqueador, e contá-la mente.

**Audita a resposta da IA com aritmética.** Cada sugestão é conferida contra os
dados reais da carta: identidade de cor, singleton, legalidade em Commander,
preço e impacto no bracket. Depois aplica as mudanças limpas ao deck em
memória, re-mede tudo, e mostra o antes→depois — o que resolve, o que persiste,
o que quebra.

**Otimiza em etapas, num sandbox.** O Otimizador roda uma fila de consultas
sobre uma *cópia* do deck — mana, curva, interação, consistência, o deck
inteiro, matchups, alinhamento — cada etapa vendo o que as anteriores fizeram e
por quê, com checkpoints de estabilização no meio. A lista real nunca é tocada
até você mandar salvar. Uma carta pode entrar e sair uma vez; na segunda o
motor encerra o vaivém.

**Ou reimagina.** O mesmo pipeline num modo que primeiro devolve **três
direções diferentes** para o deck — arquétipo e tema, com a tese e o que se
perde em cada uma — e para, esperando você escolher. A direção escolhida vira o
contrato das etapas seguintes. O comandante pode mudar, desde que a identidade
de cor seja exatamente a mesma.

**Trata preço como fato, não como palpite.** O preço de uma carta é o da
**edição mais barata** — não o da edição que a busca por nome devolveu, que
costuma ser a mais nova e às vezes não tem preço nenhum. E como preço não diz
se a carta é boa (a mais barata que uma IA já sugeriu aqui foi Arcane Signet, a
3ª carta mais jogada do formato), cada sugestão mostra também **quanto do
formato joga aquela carta** — exibido, nunca aplicado como regra.

**O orçamento é uma contagem, não uma linha.** Em vez de um teto por carta, o
deck tem uma forma: quantas cartas caras aceita, e quantas exceções acima do
teto — porque existe a carta que vale quebrar a própria regra, e ela precisa
caber.

**Não dá nota de 1 a 10.** É recusa deliberada: um power level é um algoritmo
que ranqueia toda carta de Magic, que é exatamente o que este projeto existe
para não fazer.

## Rodando

Precisa de Elixir 1.19.5 / OTP 27 e Docker.

```bash
docker compose up -d
mix setup
mix phx.server
```

O Postgres sobe na porta **5435**. Abre http://localhost:4005.

## Importando um deck

**Colando a lista** é o caminho principal e funciona sempre, inclusive pra deck
privado: no Moxfield, abre o deck → Export → copia → cola no app.

**Sync pela URL** está implementado, mas o Moxfield responde **403 (Cloudflare)**
para clientes não aprovados — testado em 13/08/2026 com um User-Agent honesto.
Se você conseguir um User-Agent aprovado com o support@moxfield.com, cola ele em
Ajustes e o sync passa a funcionar sem mudança de código. O app não faz e não vai
fazer evasão de detecção.

## Qualidade

```bash
mix lint
```

Roda `format --check-formatted`, `deps.unlock --check-unused`, `credo --strict`,
`sobelow --config` e `dialyzer`. Tem que estar verde antes de todo commit.

```bash
mix precommit
```

Roda `compile --warnings-as-errors`, `deps.unlock --unused`, `format` e `test`.

Nenhum teste toca a rede: a Scryfall é uma porta com mock Mox, e as respostas
usadas nos testes são payloads reais commitados em
`test/support/fixtures/scryfall/`.

## Documentação

| Arquivo | O quê |
|---|---|
| [`AGENTS.md`](AGENTS.md) | Contrato operacional — convenções e as leis do projeto |
| [`docs/superpowers/specs/`](docs/superpowers/specs/) | O spec de design: o quê e por quê |
| [`docs/superpowers/plans/`](docs/superpowers/plans/) | Planos de implementação, task a task |
| [`docs/playbook/`](docs/playbook/) | Playbook de arquitetura Elixir/Phoenix |
