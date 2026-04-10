# kingsland-setup

Cloudflare Worker que serve um script idempotente de bootstrap do ambiente macOS em
`https://kingsland.network/setup.sh`.

## Uso (na máquina nova)

```sh
curl -fsSL https://kingsland.network/setup.sh | bash
```

Ou, para evitar problemas com partes interativas (`sudo`, `chsh`):

```sh
curl -fsSL https://kingsland.network/setup.sh -o /tmp/setup.sh && bash /tmp/setup.sh
```

O script é idempotente: ele detecta o que já está instalado e só aplica o que
falta.

## Desenvolvimento local

```sh
# 1. instalar dependências
npm install

# 2. autenticar no Cloudflare (só precisa fazer 1x)
npx wrangler login

# 3. dev server local
npm run dev
# depois: curl http://localhost:8787/setup.sh
```

## Deploy

```sh
npm run deploy
```

O worker é publicado com o nome `kingsland-setup` e roteado para
`kingsland.network/setup.sh` (configurado em `wrangler.toml`).

> Pré-requisito: o domínio `kingsland.network` precisa estar no mesmo account
> Cloudflare em que você está autenticado com o `wrangler`.

## Editando o script

Todo o conteúdo do `setup.sh` está em `src/setup.sh`. O `src/worker.js` importa
esse arquivo como texto (via regra `Text` no `wrangler.toml`) e responde tanto
em `/` quanto em `/setup.sh`.

Fluxo típico de atualização:

```sh
# edite src/setup.sh
npm run dev      # testa local
npm run deploy   # publica
```

## Estrutura

```
kingsland-setup/
├── src/
│   ├── worker.js      # worker Cloudflare (serve o script)
│   └── setup.sh       # o script em si
├── wrangler.toml      # config do worker + rota
├── package.json
└── README.md
```
