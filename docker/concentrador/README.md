# Concentrador de Logs — infraestrutura local (Docker Compose)

Esta pasta sobe, via Docker Compose, toda a infraestrutura da máquina
concentradora descrita em [`arquitetura.md`](../../arquitetura.md): recepção
de logs no formato Filebeat, gravação organizada em disco, rotação/retenção e
observabilidade (Prometheus + Grafana). As aplicações que geram os logs
**não** fazem parte deste compose — elas rodam separadamente em
[`docker/apps`](../apps/) (compose próprio) e simulam instâncias/containers
reais enviando logs para cá.

Os dois compose files se comunicam por uma rede Docker externa chamada
`vector-stack`: **este** compose (`concentrador`) é quem a cria (via
`networks.vector-stack.name`); o compose de `docker/apps` só a referencia
(`external: true`). Por isso **suba o concentrador antes das apps** — veja
"Como executar" abaixo.

## Serviços

| Serviço | Imagem | Função |
|---|---|---|
| `vector` | `timberio/vector` | Recebe eventos no protocolo Filebeat/Logstash (Beats) na porta 5044 e grava cada linha em `/mnt/logs/{app}/{data}/{instancia}/{app}.log` (arquivo "atual", sempre com o mesmo nome) |
| `rotator` | build local (`rotator/`) | A cada hora, "fecha" o `{app}.log` de cada app/instância: copia para `{app}-{HH}.log`, trunca o original no lugar (copytruncate — o Vector continua escrevendo sem interrupção) e compacta a cópia em `.gz`. Implementa o item 5 do `arquitetura.md` |
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
UID=$(id -u) GID=$(id -g) docker compose up -d --build
```

O `UID`/`GID` na frente faz o `vector` e o `rotator` (os dois serviços que
escrevem em `data/logs`) rodarem com o seu usuário do host em vez de
`root` — senão os arquivos gravados ali ficam donos de `root` e você não
consegue lê-los/movê-los do host depois (o `scripts/archive-logs.sh`, por
exemplo, precisa rodar como o dono dos arquivos). Repita o prefixo em
qualquer outro `docker compose` rodado nesta pasta.

Isso cria também, na primeira execução, a pasta `data/` (logs, métricas
textfile), os volumes nomeados do Prometheus e do Grafana, e a rede Docker
externa `vector-stack` usada pelas apps em `docker/apps` para alcançar o
Vector pelo nome do serviço (`vector:5044`).

Depois, para subir as apps que geram log (opcional, servem para gerar
tráfego de teste): veja [`docker/apps/README.md`](../apps/README.md).

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
data/logs/{app}/{YYYY-MM-DD}/{instance}/{app}.log
```

Esse é o arquivo "atual" — o `rotator` cuida de fechá-lo a cada hora (ver
seção "Rotação e retenção" abaixo), então ele nunca cresce indefinidamente e
sempre existe com esse nome fixo para acompanhar com `tail -f`.

Em `docker/apps` isso já vem pronto: cada app tem seu próprio
`filebeat-<nome>.yml` e roda o Filebeat no mesmo container, sem precisar
reescrever esse trecho manualmente — veja
[`docker/apps/README.md`](../apps/README.md).

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
tail -f data/logs/customers-app/2026-08-15/i-0abc123/customers-app.log
```

Para acompanhar várias aplicações/instâncias ao mesmo tempo:

```bash
multitail data/logs/*/*/*/*.log
# ou, sem multitail instalado:
tail -f data/logs/*/*/*/*.log
```

Isso pega tanto os `{app}.log` atuais quanto os `{app}-{HH}.log` ainda não
compactados. Os `.log.gz` já rotacionados ficam só para histórico
(`zcat`/`zless`).

## Rotação e retenção

- **A cada hora** (serviço `rotator`, cron interno): o `{app}.log` corrente
  vira `{app}-{HH}.log` (HH = hora que acabou de fechar) e é compactado para
  `{app}-{HH}.log.gz`; um novo `{app}.log` vazio continua recebendo os logs
  no mesmo lugar, sem o Vector perceber (copytruncate — depende de o Vector
  escrever em modo append, o que é o padrão). Implementa o item 5 do
  `arquitetura.md`. Script: `rotator/rotate-logs.sh`, agendado via
  `rotator/crontab` (`0 * * * *`).
- **Após 30 dias**: script avulso `scripts/archive-logs.sh` (não roda como
  serviço — execute manualmente ou agende no cron do host) move os `.gz` de
  pastas de data com mais de 30 dias para `data/logs/archive/{app}/{data}/
  {instancia}/`, mantendo a estrutura, conforme o item 6 do `arquitetura.md`:
  ```bash
  ./scripts/archive-logs.sh                 # usa data/logs e 30 dias por padrão
  ./scripts/archive-logs.sh data/logs 30     # explícito
  ```
  Sugestão de cron do host (diário, às 3h):
  ```
  0 3 * * * /caminho/completo/docker/concentrador/scripts/archive-logs.sh >> /var/log/archive-logs.log 2>&1
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
├── vector/vector.yaml              # source logstash:5044 -> sink file templado (sem hora no path)
├── rotator/
│   ├── Dockerfile
│   ├── rotate-logs.sh              # copytruncate + gzip do log corrente, roda de hora em hora
│   └── crontab
├── prometheus/prometheus.yml       # scrape do node-exporter
├── textfile-collector/
│   ├── Dockerfile
│   └── log-metrics.sh              # gera métricas .prom de tamanho/último log por app
├── grafana/provisioning/
│   ├── datasources/datasource.yml
│   └── dashboards/{dashboard.yml,concentrador.json}
├── scripts/
│   ├── send-test-log.py            # simula um Filebeat para testes
│   └── archive-logs.sh             # script avulso: move .gz com +30 dias para data/logs/archive/
└── data/
    ├── logs/                       # volume local dos logs (o que você acompanha com tail -f)
    │   └── archive/                # criado pelo archive-logs.sh, mesma estrutura app/data/instância
    └── textfile/                   # métricas custom (.prom) lidas pelo node-exporter
```

As apps que geram log ficam em [`../apps`](../apps/) (compose separado).

## Pendências conhecidas (fora do escopo desta etapa)

- Alertas no Grafana (thresholds descritos em `arquitetura.md`, ainda não
  provisionados).
- TLS entre Filebeat e Vector (arquitetura decidiu adiar, ver
  `arquitetura.md` § Segurança).
