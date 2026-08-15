# Concentrador de Logs — infraestrutura local (Docker Compose)

Esta pasta sobe, via Docker Compose, toda a infraestrutura da máquina
concentradora descrita em [`arquitetura.md`](../../arquitetura.md): recepção
de logs no formato Filebeat, gravação organizada em disco e observabilidade
(Prometheus + Grafana). As aplicações que geram os logs **não** fazem parte
deste compose — elas rodam separadamente (ver `docker/apps`, ainda vazio) e
simulam instâncias/containers reais enviando logs para cá.

## Serviços

| Serviço | Imagem | Função |
|---|---|---|
| `vector` | `timberio/vector` | Recebe eventos no protocolo Filebeat/Logstash (Beats) na porta 5044 e grava cada linha em `/mnt/logs/{app}/{data}/{instancia}/{app}-{hora}.log` |
| `node-exporter` | `prom/node-exporter` | Expõe métricas de sistema (disco, CPU, memória, inodes, file descriptors) do host onde o Docker roda |
| `textfile-collector` | build local (`textfile-collector/`) | A cada 15 min (configurável), calcula tamanho em disco e timestamp do último log de cada app e escreve como métrica custom, lida pelo `node-exporter` |
| `prometheus` | `prom/prometheus` | Faz scrape do `node-exporter` |
| `grafana` | `grafana/grafana` | Dashboard "Concentrador de Logs — Visão Geral", carregado automaticamente, **sem autenticação** |

## Endpoints (host)

| Serviço | URL/porta local | Observação |
|---|---|---|
| Vector (entrada de logs) | `tcp://localhost:5044` | Filebeat aponta `output.logstash.hosts` para cá |
| node-exporter | http://localhost:9100/metrics | |
| Prometheus | http://localhost:9091 | Mapeado em 9091 (não 9090) porque já havia outro Prometheus rodando neste host — ajuste em `docker-compose.yml` se seu ambiente estiver livre |
| Grafana | http://localhost:3001 | Mapeado em 3001 (não 3000) pelo mesmo motivo. Abre direto no dashboard, sem tela de login |

## Como executar

```bash
cd docker/concentrador
docker compose up -d --build
```

Isso cria também, na primeira execução, a pasta `data/` (logs, métricas
textfile) e os volumes nomeados do Prometheus e do Grafana.

Para parar:

```bash
docker compose down
```

(os dados em `data/` e nos volumes nomeados permanecem; para limpar tudo,
`docker compose down -v` também remove os volumes nomeados — os logs em
`data/logs` continuam no disco pois são bind mount, não volume).

## Como uma aplicação cliente envia logs

Qualquer app roda um **Filebeat** local apontando para o seu arquivo de log,
com os campos `app` e `instance` preenchidos — é a única configuração
específica por aplicação; o Vector não precisa de nenhuma mudança para
receber uma app nova:

```yaml
filebeat.inputs:
  - type: log
    paths:
      - /var/log/minha-app/*.log
    fields:
      app: minha-app
      instance: ${INSTANCE_ID}   # hostname, EC2 instance-id ou Nomad alloc ID
    fields_under_root: false

output.logstash:
  hosts: ["localhost:5044"]   # em produção: concentrador.interno:5044
```

O Vector lê `fields.app` e `fields.instance` do evento para montar o caminho
do arquivo automaticamente:

```
data/logs/{app}/{YYYY-MM-DD}/{instance}/{app}-{HH}.log
```

### Testando sem subir um Filebeat de verdade

O protocolo usado pelo Filebeat (`output.logstash`) é binário (lumberjack/
Beats), então não dá para simular com `curl`/`netcat` puro. Para isso existe
`scripts/send-test-log.py`, que fala esse protocolo e manda um evento de
teste direto ao Vector:

```bash
python3 scripts/send-test-log.py localhost 5044 customers-app i-0abc123 "log de teste"
```

Um `ACK recebido do Vector` confirma que o evento chegou; o arquivo aparece
em segundos em `data/logs/customers-app/...`.

## Visualizando os logs em tempo real

Os logs ficam organizados em disco no volume local `data/logs` (bind mount,
fora dos containers — é o que o requisito de "volume local" pedia):

```bash
tail -f data/logs/customers-app/2026-08-11/i-0abc123/customers-app-14.log
```

Para acompanhar várias aplicações/instâncias ao mesmo tempo:

```bash
multitail data/logs/*/*/*/*.log
# ou, sem multitail instalado:
tail -f data/logs/*/*/*/*.log
```

## Dashboard no Grafana

Acesse http://localhost:3001 — o dashboard **"Concentrador de Logs — Visão
Geral"** já vem carregado (provisionado automaticamente a partir de
`grafana/provisioning/`), com:

- Tabela de aplicações enviando logs (tamanho em disco + há quanto tempo foi
  o último log recebido).
- Gauge de disco usado no volume de logs.
- Memória disponível.
- Inodes livres e file descriptors usados (sinais de risco específicos deste
  tipo de carga, muitos arquivos pequenos).
- Load average e uso de CPU.
- I/O de disco.

Alertas (thresholds de disco, inodes, load, etc. descritos em
`arquitetura.md`) **não** foram provisionados nesta etapa — ficam para uma
próxima rodada.

## Estrutura de pastas

```
docker/concentrador/
├── docker-compose.yml
├── vector/vector.yaml              # source logstash:5044 -> sink file templado
├── prometheus/prometheus.yml       # scrape do node-exporter
├── textfile-collector/
│   ├── Dockerfile
│   └── log-metrics.sh              # gera métricas .prom de tamanho/último log por app
├── grafana/provisioning/
│   ├── datasources/datasource.yml
│   └── dashboards/{dashboard.yml,concentrador.json}
├── scripts/send-test-log.py        # simula um Filebeat para testes
└── data/
    ├── logs/                       # volume local dos logs (o que você acompanha com tail -f)
    └── textfile/                   # métricas custom (.prom) lidas pelo node-exporter
```

## Pendências conhecidas (fora do escopo desta etapa)

- Job de retenção (limpeza de logs com mais de 30 dias).
- Alertas no Grafana.
- Aplicações cliente reais em `docker/apps` (por enquanto só a pasta existe).
