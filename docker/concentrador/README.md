# Concentrador de Logs — infraestrutura local (Docker Compose)

Esta pasta sobe, via Docker Compose, só o **Vector** — a peça que recebe
logs no formato Filebeat/Logstash e grava cada linha organizada em disco.
É uma versão mínima do concentrador descrito em
[`arquitetura.md`](../../arquitetura.md): rotação, arquivamento e
observabilidade (Prometheus/Grafana) não fazem parte deste compose — a
intenção aqui é só ter o Vector escutando na 5044 para receber logs de
aplicações rodando no host (ou em `docker/apps`), e acompanhar o resultado
em `data/logs`.

## Serviço

| Serviço | Imagem | Função |
|---|---|---|
| `vector` | `timberio/vector` | Recebe eventos no protocolo Filebeat/Logstash (Beats) na porta 5044 e grava cada linha em `/mnt/logs/{app}/{data}/{instancia}/{app}.log` (arquivo "atual", sempre com o mesmo nome) |

## Endpoint (host)

| Serviço | URL/porta local | Observação |
|---|---|---|
| Vector (entrada de logs) | `tcp://localhost:5044` | Filebeat aponta `output.logstash.hosts` para cá |

## Como executar

```bash
cd docker/concentrador
UID=$(id -u) GID=$(id -g) docker compose up -d
```

O `UID`/`GID` na frente faz o `vector` (o serviço que escreve em
`data/logs`) rodar com o seu usuário do host em vez de `root` — senão os
arquivos gravados ali ficam donos de `root` e você não consegue lê-los do
host depois.

Isso cria também, na primeira execução, a pasta `data/logs` e a rede
Docker externa `vector-stack`, usada pelas apps em `docker/apps` (se você
optar por rodá-las em container em vez de no host) para alcançar o Vector
pelo nome do serviço (`vector:5044`).

Para parar:

```bash
docker compose down
```

(os logs em `data/logs` continuam no disco, pois são bind mount, não
volume nomeado).

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

Se as apps rodarem direto no host (fora de container) apontando o Filebeat
para `localhost:5044`, esse arquivo chega igual em `data/logs` — não muda
nada do lado do Vector.

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

## Estrutura de pastas

```
docker/concentrador/
├── docker-compose.yml
├── vector/vector.yaml              # source logstash:5044 -> sink file templado (sem hora no path)
├── scripts/
│   ├── send-test-log.py            # simula um Filebeat para testes
│   └── archive-logs.sh             # script avulso: move .gz com +30 dias para data/logs/archive/
└── data/
    └── logs/                       # volume local dos logs (o que você acompanha com tail -f)
```

`scripts/archive-logs.sh` continua aqui como utilitário avulso (não é
serviço deste compose) — só faz sentido rodá-lo depois que algo estiver
gerando os `.gz` que ele move (rotação, hoje só implementada na automação
Ansible real, ver `../../AWS.md`).

As apps que geram log ficam em [`../apps`](../apps/) (compose separado, se
você optar por rodá-las em container).

## Pendências conhecidas (fora do escopo desta etapa)

- Rotação horária, arquivamento contínuo e métricas/dashboard (Prometheus +
  Grafana), descritos em `arquitetura.md`, não fazem parte deste compose
  simplificado — só do provisionamento Ansible real (`../../AWS.md`).
- TLS entre Filebeat e Vector (arquitetura decidiu adiar, ver
  `arquitetura.md` § Segurança).
