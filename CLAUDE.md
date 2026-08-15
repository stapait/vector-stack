# vector-stack

Centralização de logs de múltiplas aplicações (EC2 + containers Nomad) numa
EC2 concentradora rodando Vector, com acompanhamento em tempo real via
tail/multitail e métricas no Grafana/Prometheus existentes.

Decisões de arquitetura completas em [`arquitetura.md`](./arquitetura.md) —
ler antes de propor mudanças de design, para não repetir discussões já
fechadas (ex.: por que Vector em vez de Logstash, por que sem TLS por ora).

## Estado atual

- Implementação local (Docker Compose) da arquitetura completa, funcionando
  ponta a ponta e validada manualmente:
  - `docker/concentrador/`: Vector (recebe Filebeat/Logstash na 5044, grava
    `{app}.log` estável por app/dia/instância), `rotator` (rotação horária
    via copytruncate + gzip — requisito 5), `node-exporter` +
    `textfile-collector` + Prometheus + Grafana (dashboard provisionado),
    script avulso `scripts/archive-logs.sh` (arquivamento após 30 dias —
    requisito 6, não é serviço contínuo).
  - `docker/apps/`: 3 apps fictícias (`orders-app`, `payments-app`,
    `shipping-app`), cada uma um container com NestJS simples (gera log
    aleatório em arquivo local) + Filebeat no mesmo container, todas usando
    a mesma imagem (`docker/apps/app/`) parametrizada por `APP_NAME`. Compose
    separado do concentrador, conectado via rede Docker externa
    `vector-stack` (criada pelo compose do concentrador).
- README na raiz (`README.md`) explica a arquitetura em alto nível e tem o
  passo a passo de como subir/testar tudo via Docker.
- Detalhes de como rodar, testar e adicionar uma nova app estão nos READMEs
  de cada pasta (`docker/concentrador/README.md`, `docker/apps/README.md`) —
  ler antes de mexer, para não repetir decisões (ex.: por que
  `--strict.perms=false` no Filebeat, por que copytruncate na rotação, por
  que `UID`/`GID` precisam ser passados ao `docker compose up` do
  concentrador — sem isso o Vector grava `data/logs` como `root` e o host
  não consegue ler/mover esses arquivos depois).

## Próximo passo

Itens ainda em aberto (ver "Pendências conhecidas" em
`docker/concentrador/README.md`):
- Alertas no Grafana (thresholds já descritos em `arquitetura.md`).
- TLS entre Filebeat e Vector (adiado por decisão de arquitetura).
- Validar em ambiente real (EC2/Nomad) — tudo hoje foi testado só localmente
  via Docker Compose.

## Convenção

Manter este arquivo atualizado conforme o projeto avança (decisões novas,
estado atual, próximos passos), para que o contexto siga o repositório em
qualquer máquina só com `git pull`.
