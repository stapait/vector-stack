# Apps de exemplo — geradoras de log

Compose **separado** do `docker/concentrador`, simulando aplicações reais
(EC2/Nomad) que escrevem log local e enviam para a concentradora via
Filebeat. Cada app roda em um único container com dois processos:

1. Uma aplicação **NestJS** mínima que só fica escrevendo linhas de log
   aleatórias em `/var/log/app/<nome>.log` (sem servidor HTTP — é um
   `NestFactory.createApplicationContext`, propositalmente simples).
2. Um **Filebeat** no mesmo container, lendo esse arquivo e enviando para o
   Vector da concentradora (`vector:5044`).

Todas as apps usam a **mesma imagem** (`build: ./app`) — o que muda entre
elas é só a variável `APP_NAME`/`LOG_FILE` e o arquivo de Filebeat montado.

## Pré-requisito: suba o concentrador primeiro

Este compose referencia a rede Docker `vector-stack` como `external: true` —
quem cria essa rede é o `docker/concentrador/docker-compose.yml`. Então:

```bash
cd ../concentrador && UID=$(id -u) GID=$(id -g) docker compose up -d --build   # cria a rede vector-stack
cd ../apps && docker compose up -d --build
```

(o `UID`/`GID` só é necessário no compose do concentrador — é ele que grava
em `data/logs`; veja o motivo no `docker/concentrador/README.md`.)

## Apps incluídas

| App | Filebeat config | `fields.app` enviado ao Vector |
|---|---|---|
| `orders-app` | `filebeat/filebeat-orders-app.yml` | `orders-app` |
| `payments-app` | `filebeat/filebeat-payments-app.yml` | `payments-app` |
| `shipping-app` | `filebeat/filebeat-shipping-app.yml` | `shipping-app` |

`fields.instance` é preenchido automaticamente com o hostname do container
(`${HOSTNAME}`, interpolado pelo próprio Filebeat) — não precisa editar isso
por app.

## Adicionando uma 4ª app (sem tocar no lado do servidor)

Exatamente o requisito do `arquitetura.md`: nenhuma mudança no Vector.

1. Copie um dos arquivos em `filebeat/`, ex. `filebeat-orders-app.yml` →
   `filebeat-billing-app.yml`, e troque `app: orders-app` →
   `app: billing-app` (e o `paths:` para `/var/log/app/billing-app.log`).
2. Copie um bloco de serviço no `docker-compose.yml` (ex. o de
   `orders-app`), cole, e ajuste `container_name`, `APP_NAME`, `LOG_FILE` e
   o volume do Filebeat para apontar para o novo arquivo do passo 1.
3. `docker compose up -d --build`.

O Vector já aceita a nova app automaticamente — ele só lê os `fields` que
chegam no evento, não tem lista fixa de apps configurada.

## Verificando que está funcionando

```bash
docker compose logs -f orders-app          # vê o Nest + o Filebeat no mesmo stream
tail -f ../concentrador/data/logs/orders-app/*/*/orders-app.log
```

## Por que Filebeat e não outra coisa no container da app

O `arquitetura.md` já fixou Filebeat como o agente de origem (compatível com
o `source: logstash` do Vector). Aqui ele roda dentro do mesmo container da
app só para simular o cenário real de uma instância EC2/task Nomad, onde
Filebeat roda ao lado da aplicação lendo o arquivo local dela.

Detalhe de implementação: o Filebeat sobe com `--strict.perms=false` porque
o arquivo de config é bind-mounted do host (dono é o seu usuário local, não
`root` dentro do container) — sem essa flag o Filebeat recusa subir. Isso é
específico deste ambiente de desenvolvimento local; numa EC2 real o arquivo
pertenceria ao usuário certo e a flag não seria necessária.
