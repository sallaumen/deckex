# deckex

Análise de decks de Commander (EDH). Você importa a lista, o app mede a forma do
deck — curva, mana, interação, consistência — e leva esses números pra uma IA com
busca na web, que sugere o que cortar e o que colocar.

O app **não** decide se uma carta é boa. Ele mede o *seu* deck e deixa a parte de
opinião pra IA, que conhece o pool de cartas inteiro. É de propósito: mapear as
~30 mil cartas de Magic já foi feito, e feito melhor, em outros lugares.

## Status

Em construção. O que já funciona:

- **Catálogo de cartas** — resolve nomes contra a Scryfall e guarda pra sempre.
  Carta conhecida sai do Postgres; só carta nova custa requisição. Trata cartas
  de duas faces (MDFC), preço, e rank do EDHREC.

O que vem: classificação de papéis das cartas (ramp, counter, removal…),
importação de decks, as quatro lentes de diagnóstico, e a interface. Veja
[`docs/superpowers/plans/`](docs/superpowers/plans/).

## Rodando

Precisa de Elixir 1.19.5 / OTP 27 e Docker.

```bash
docker compose up -d
mix setup
mix phx.server
```

O Postgres sobe na porta **5435**. Abre http://localhost:4000.

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
