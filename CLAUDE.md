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
- Automação Ansible (`ansible/vector-provision.yml`, detalhes em `AWS.md`
  e em `ansible/README.md`) provisiona a EC2 concentradora real (Vector,
  node_exporter, textfile collector, logrotate, arquivamento) — validada de
  ponta a ponta contra Amazon Linux 2023 real de duas formas, sem depender
  de conta AWS: `docker/local-ec2/` (container com systemd) e `vagrant/`
  (VM VirtualBox, box `bento/amazonlinux-2023` — mais fiel, kernel próprio
  da imagem). Nenhuma incompatibilidade nova apareceu na VM Vagrant; os
  bugs reais (ex. `findutils` faltando) já tinham sido pegos e corrigidos
  rodando contra o `local-ec2` antes. Variáveis ficam em
  `ansible/group_vars/vector.yml` (não `vars/`) — carregadas
  automaticamente pelo grupo `[vector]` usado nas três inventories, sem
  precisar de `-e` na linha de comando; arquivos da pasta `ansible/` não
  têm comentários internos, explicações ficam em `ansible/README.md`.
- `apps/`: equivalente ao `docker/apps/`, mas rodando direto no host (sem
  Docker) — 3 apps NestJS autocontidas (`app1/`, `app2/`, `app3/`, cada
  uma sua própria pasta com `APP_NAME` fixo no código, já que aqui não há
  `docker-compose` para parametrizar uma imagem só por env var), cada uma
  escrevendo em `apps/<nome>/logs/<nome>.log`. `apps/filebeat/filebeat.yml`
  é a cópia versionada do config usado pelo Filebeat instalado no host
  (`/home/fabio/filebeat-9.5.1-linux-x86_64`), com um input por app,
  enviando para o Vector da VM Vagrant (`192.168.56.20:5044`). Ainda não
  executado (nem o Filebeat nem as apps) — só o ambiente/instruções foram
  criados, ver `apps/README.md`. Bloqueio conhecido: **Node.js não está
  instalado neste host**.

## Próximo passo

- Instalar Node.js no host, rodar as 3 apps de `apps/` e o Filebeat
  apontado para elas (`apps/README.md`), e confirmar na VM Vagrant que os
  logs chegam via rede real (não só o evento de teste sintético usado até
  agora).

Itens ainda em aberto (ver "Pendências conhecidas" em
`docker/concentrador/README.md`):
- Alertas no Grafana (thresholds já descritos em `arquitetura.md`).
- TLS entre Filebeat e Vector (adiado por decisão de arquitetura).

## Convenção

Manter este arquivo atualizado conforme o projeto avança (decisões novas,
estado atual, próximos passos), para que o contexto siga o repositório em
qualquer máquina só com `git pull`.
