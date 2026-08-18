# Concentrador de Logs — infraestrutura local (Docker Compose)

Esta pasta sobe, via Docker Compose, o **Vector** (recebe logs no formato
Filebeat/Logstash e grava cada linha organizada em disco) e a
**observabilidade** em torno dele — `node_exporter` + um coletor de
métricas custom por app, com Prometheus fazendo o scrape e Grafana
exibindo um dashboard já provisionado. É uma versão local do concentrador
descrito em [`arquitetura.md`](../../arquitetura.md) — rotação e
arquivamento continuam fora deste compose (só existem de verdade na
automação Ansible, ver [`../../AWS.md`](../../AWS.md)); métricas/dashboard
seguem o mesmo design descrito lá (seção "## Métricas"), só que rodando em
containers em vez de systemd.

## Serviços

| Serviço | Imagem | Função |
|---|---|---|
| `vector` | `timberio/vector` | Recebe eventos no protocolo Filebeat/Logstash (Beats) na porta 5044 e grava cada linha em `/mnt/logs/{app}/{data}/{instancia}/{app}.log` (arquivo "atual", sempre com o mesmo nome) |
| `node-exporter` | `prom/node-exporter` | Métricas padrão da máquina (disco, CPU, memória, load, inodes, file descriptors, I/O) + lê os `.prom` gerados pelo `textfile-collector` |
| `textfile-collector` | build local (`textfile-collector/`) | A cada 15 min (`INTERVAL_SECONDS`), varre `data/logs/{app}` e escreve `log_app_disk_bytes` e `log_app_last_write_timestamp_seconds` por app em `data/textfile/log_app_metrics.prom` |
| `prometheus` | `prom/prometheus` | Faz scrape do `node-exporter` (que inclui as métricas custom acima) |
| `grafana` | `grafana/grafana` | Dashboard "Concentrador de Logs - Visão Geral", provisionado automaticamente (datasource + dashboard JSON em `grafana/provisioning/`) — nada para importar manualmente |

## Endpoints (host)

| Serviço | URL/porta local | Observação |
|---|---|---|
| Vector (entrada de logs) | `tcp://localhost:5044` | Filebeat aponta `output.logstash.hosts` para cá |
| node_exporter | `http://localhost:9100/metrics` | Inclui `log_app_disk_bytes`/`log_app_last_write_timestamp_seconds` |
| Prometheus | `http://localhost:9091` | Porta `9091` (não `9090`) porque outro Prometheus já roda nesta máquina |
| Grafana | `http://localhost:3001` | Porta `3001` (não `3000`) pelo mesmo motivo; login anônimo como Admin (`GF_AUTH_ANONYMOUS_ENABLED`), abre direto no dashboard, sem tela de login |

## Como executar

```bash
cd docker/concentrador
mkdir -p data/logs data/textfile
UID=$(id -u) GID=$(id -g) docker compose up -d
```

O `mkdir -p` precisa vir *antes* do `docker compose up`: se essas pastas
não existirem, o Docker as cria sozinho como bind mount, mas donas de
`root` (mesmo com `user:` setado no serviço) — aí nem o `vector` nem o
`textfile-collector`, rodando com seu `UID`/`GID`, conseguem escrever
nelas. Criando-as você mesmo antes, ficam do seu usuário e tudo funciona.

O `UID`/`GID` na frente do `docker compose up` faz `vector` e
`textfile-collector` (os serviços que escrevem em `data/logs` e
`data/textfile`) rodarem com o seu usuário do host em vez de `root` —
senão os arquivos gravados ali ficam donos de `root` e você não consegue
lê-los/apagá-los do host depois. Repita esse prefixo em qualquer
`docker compose` rodado nesta pasta (`up`, `restart` etc.).

Para parar:

```bash
docker compose down
```

(os dados em `data/logs` e `data/textfile` continuam no disco, pois são
bind mount, não volume nomeado; `prometheus`/`grafana` usam volumes
nomeados próprios, que também sobrevivem ao `down` — só `down -v` os
apaga).

## Como uma aplicação cliente envia logs

Qualquer app roda um **Filebeat** local apontando para o seu arquivo de log,
com o campo `app` preenchido — é a única configuração específica por
aplicação; o Vector não precisa de nenhuma mudança para receber uma app
nova:

```yaml
filebeat.inputs:
  - type: log
    paths:
      - /var/log/minha-app/*.log
    fields:
      app: minha-app
    fields_under_root: false

output.logstash:
  hosts: ["localhost:5044"]   # em produção: concentrador.interno:5044
```

Não precisa de um campo `instance`: o libbeat (motor do Filebeat) já inclui
um `host.name` (hostname da máquina onde o Filebeat roda) em todo evento,
por padrão, independente de config — o Vector usa isso direto no path do
sink.

O Vector lê `fields.app` e `host.name` do evento para montar o caminho
do arquivo automaticamente:

```
data/logs/{app}/{YYYY-MM-DD}/{host.name}/{app}.log
```

Se as apps rodarem direto no host (fora de container) apontando o Filebeat
para `localhost:5044`, esse arquivo chega igual em `data/logs` — não muda
nada do lado do Vector.

Os logs de verdade vêm das apps de teste em [`../../apps`](../../apps/),
rodando direto no host com um Filebeat apontando pra cá — não há script de
simulação de Filebeat nesta pasta; sem as apps/Filebeat de pé, não há log
chegando.

## Visualizando os logs em tempo real

Os logs ficam organizados em disco no volume local `data/logs` (bind mount,
fora do container):

```bash
tail -f data/logs/customers-app/2026-08-15/i-0abc123/customers-app.log
```

Para acompanhar várias aplicações/instâncias ao mesmo tempo:

```bash
multitail data/logs/*/*/*/*.log
# ou, sem multitail instalado:
tail -f data/logs/*/*/*/*.log
```

## Dashboard no Grafana

Um único dashboard, "Concentrador de Logs - Visão Geral", carregado
automaticamente ao subir o `grafana` (provisioning em
`grafana/provisioning/`, sem import manual):

- **Aplicações enviando logs** (tabela): uma linha por app, com tamanho em
  disco (`log_app_disk_bytes`, soma de todos os dias/instâncias daquela
  app — é o "consumo total em MB" pedido) e há quanto tempo chegou o
  último log (`log_app_last_write_timestamp_seconds`). Uma app parada de
  enviar aparece na mesma tabela com "Último log" crescendo — esse é o
  sinal de "app pode estar gerando problema" coberto por este dashboard
  (ver nota abaixo sobre o que fica de fora).
- **Disco usado**, **inodes livres** e **file descriptors usados**
  (gauges com threshold verde/amarelo/vermelho) e **memória disponível**
  (stat) — saúde geral da máquina que hospeda `data/logs`.
- **Load average** e **CPU usada** (séries temporais, load normalizado
  pelo número de cores) e **I/O de disco** — sinais de que o volume de
  logs recebido pode estar sobrecarregando a máquina.

Os thresholds de alerta (disco 85%/95%, inodes 85%, etc.) estão descritos
em `arquitetura.md` § Métricas, mas os **alertas do Grafana em si não
estão configurados neste compose** — só os dashboards/painéis. Também fora
de escopo (mesma decisão registrada em `arquitetura.md`): alerta de uma
app individual crescendo com taxa anormal — o sinal disponível aqui é
"parou de enviar" (staleness), não "está crescendo rápido demais".

## Estrutura de pastas

```
docker/concentrador/
├── docker-compose.yml
├── vector/vector.yaml                          # source logstash:5044 -> sink file templado (sem hora no path)
├── prometheus/prometheus.yml                   # scrape do node-exporter
├── grafana/provisioning/
│   ├── datasources/datasource.yml              # datasource Prometheus, auto-provisionado
│   └── dashboards/
│       ├── dashboard.yml                       # provider que aponta pra esta pasta
│       └── concentrador.json                   # dashboard "Concentrador de Logs - Visão Geral"
├── textfile-collector/
│   ├── Dockerfile                              # alpine + bash/coreutils/findutils
│   └── log-metrics.sh                          # gera log_app_disk_bytes / log_app_last_write_timestamp_seconds
└── data/
    ├── logs/                                   # bind mount dos logs (o que você acompanha com tail -f)
    └── textfile/                                # bind mount dos .prom gerados pelo textfile-collector
```

As apps que geram log ficam em [`../../apps`](../../apps/) — rodam direto
no host (sem Docker), com um Filebeat apontando pra `localhost:5044`.

## Pendências conhecidas (fora do escopo desta etapa)

- Rotação horária e arquivamento contínuo, descritos em `arquitetura.md`,
  não fazem parte deste compose de propósito — este ambiente Docker é só
  para visualizar logs e dashboards; rotação/compactação/arquivamento só
  são testados na automação Ansible real (`../../AWS.md`).
- Alertas no Grafana (thresholds já descritos em `arquitetura.md`, painéis
  já existem, mas nenhuma regra de alerta está configurada).
- Alerta de app individual crescendo com taxa anormal — decisão já
  registrada como fora de escopo em `arquitetura.md` § Métricas.
- TLS entre Filebeat e Vector (arquitetura decidiu adiar, ver
  `arquitetura.md` § Segurança).
