# vector-stack

Centralização de logs de múltiplas aplicações (EC2 + containers Nomad) numa
única EC2 concentradora, com acompanhamento em tempo real via `tail -f` /
`multitail` e observabilidade no Grafana/Prometheus.

## O que essa arquitetura faz, em alto nível

Cada aplicação (rodando numa EC2 ou num container Nomad) escreve seu log
normalmente num arquivo de texto local. Um **Filebeat** ao lado da
aplicação lê esse arquivo e envia os eventos, com dois campos fixos (`app` e
`instance`), para uma máquina concentradora.

Na concentradora, o **Vector** recebe esses eventos (falando o protocolo do
Filebeat/Logstash) e grava cada linha num arquivo organizado por
app/dia/instância:

```
/mnt/logs/{app}/{YYYY-MM-DD}/{instancia}/{app}.log
```

Esse `{app}.log` é sempre o arquivo "atual" — dá para `tail -f` direto nele
a qualquer momento. Um job de **rotação** fecha esse arquivo a cada hora
(vira `{app}-{HH}.log.gz`) e um job de **arquivamento** move os `.gz` com
mais de 30 dias para uma pasta `/archive`, mantendo a mesma estrutura — a
pasta principal fica sempre só com os logs recentes.

Métricas da concentradora (disco, CPU, memória, inodes, file descriptors, e
quanto espaço cada app está ocupando) são expostas via `node_exporter` +
métricas custom, coletadas pelo Prometheus e visualizadas num dashboard do
Grafana.

O ponto central do design: **adicionar uma aplicação nova não exige nenhuma
mudança do lado da concentradora** — o Vector só lê os campos `app`/
`instance` que chegam no evento. Basta a aplicação nova rodar um Filebeat
apontando pra ela mesma.

Decisões de arquitetura completas, com as alternativas consideradas e o
porquê de cada escolha (Vector vs. Logstash, sem TLS por ora, etc.), estão
em [`arquitetura.md`](./arquitetura.md).

## Estrutura do repositório

```
arquitetura.md              # decisões de design completas
docker/
├── concentrador/           # Vector, rotator, node-exporter, Prometheus, Grafana
│   └── README.md           # detalhes de cada serviço, endpoints, rotação/retenção
└── apps/                   # apps fictícias que geram log (NestJS + Filebeat)
    └── README.md           # como rodar e como adicionar uma nova app
```

## Como executar e testar com Docker

Tudo roda localmente via Docker Compose, em dois compose files separados —
o do concentrador **precisa subir primeiro**, pois é ele quem cria a rede
Docker (`vector-stack`) usada pelas apps para alcançar o Vector.

### 1. Subir a concentradora

```bash
cd docker/concentrador
UID=$(id -u) GID=$(id -g) docker compose up -d --build
```

Isso sobe: Vector (porta `5044`, recepção de logs), `rotator` (rotação
horária), `node-exporter` (`:9100`), Prometheus (`:9091`) e Grafana
(`:3001`, sem login).

O `UID`/`GID` na frente do comando faz o Vector e o `rotator` gravarem os
arquivos em `data/logs` com o dono/grupo do seu usuário — sem isso eles
rodam como `root` dentro do container e você não consegue ler/mover esses
arquivos do host depois (ex. o `archive-logs.sh` do passo 5 falharia com
"Permission denied"). Repita esse prefixo em qualquer `docker compose`
rodado nesta pasta (`up`, `restart` etc.).

### 2. Subir as apps geradoras de log

```bash
cd ../apps
docker compose up -d --build
```

Sobe 3 apps fictícias (`orders-app`, `payments-app`, `shipping-app`), cada
uma escrevendo log local e enviando via Filebeat para o Vector.

### 3. Acompanhar os logs chegando

```bash
cd ../concentrador
tail -f data/logs/*/*/*/*.log
# ou, com multitail instalado:
multitail data/logs/*/*/*/*.log
```

Em poucos segundos deve aparecer log das 3 apps, um arquivo por
app/dia/instância.

### 4. Ver métricas no Grafana

Abra http://localhost:3001 — o dashboard **"Concentrador de Logs — Visão
Geral"** já vem carregado, mostrando as apps enviando log, disco usado,
inodes, load, etc.

### 5. Testar a rotação e o arquivamento manualmente

Sem esperar uma hora/30 dias de verdade:

```bash
# roda a rotação (copytruncate + gzip) agora, fora do horário do cron
docker exec concentrador-rotator rotate-logs.sh

# roda o arquivamento (move .gz de pastas com +30 dias para /archive)
./scripts/archive-logs.sh
```

### 6. Adicionar uma app nova (validar "zero mudança no servidor")

Veja o passo a passo em [`docker/apps/README.md`](./docker/apps/README.md)
— copiar um bloco de serviço no compose + um arquivo de Filebeat, sem
mexer em nada do lado do Vector.

### 7. Parar tudo

```bash
cd docker/apps && docker compose down
cd ../concentrador && docker compose down   # +  -v para também apagar os volumes nomeados (Prometheus/Grafana)
```

Os logs em `docker/concentrador/data/logs` são bind mount e continuam no
disco mesmo depois do `down -v`.
