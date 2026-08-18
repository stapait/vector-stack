# vector-stack

Centralização de logs de múltiplas aplicações (EC2 + containers Nomad) numa
EC2 concentradora rodando Vector, com acompanhamento em tempo real via
tail/multitail e métricas no Grafana/Prometheus existentes.

Decisões de arquitetura completas em [`arquitetura.md`](./arquitetura.md) —
ler antes de propor mudanças de design, para não repetir discussões já
fechadas (ex.: por que Vector em vez de Logstash, por que sem TLS por ora).

## Estado atual

- Implementação local (Docker Compose) com Vector + observabilidade —
  rotação e arquivamento continuam fora deste sandbox (só existem de
  verdade na automação Ansible, `ansible/`, `AWS.md`), mas métricas e
  dashboard (Grafana/Prometheus) foram trazidos de volta, seguindo o mesmo
  design já descrito em `arquitetura.md` § Métricas (node_exporter +
  textfile collector, só que em containers em vez de systemd):
  - `docker/concentrador/`: `vector` (recebe Filebeat/Logstash na 5044,
    grava `{app}.log` estável por app/dia/instância), `node-exporter` +
    `textfile-collector` (gera `log_app_disk_bytes` e
    `log_app_last_write_timestamp_seconds` por app, varrendo `data/logs` a
    cada 15 min), `prometheus` (`:9091` — não `9090`, já ocupada neste
    host) e `grafana` (`:3001` — não `3000`, mesmo motivo; dois dashboards
    provisionados automaticamente via `grafana/provisioning/`, sem import
    manual: "Concentrador de Logs - Visão Geral" (apps) e "Concentrador -
    Saúde da Instância" (CPU/memória/disco/rede/inodes do node_exporter,
    focado em identificar gargalo quando muitos apps enviam log ao mesmo
    tempo)). Sem script de simulação de
    Filebeat (removido — os logs de verdade vêm das apps de `apps/` via
    Filebeat no host) e sem rotação nem arquivamento de propósito — este
    ambiente Docker é só para visualizar
    logs e dashboards; rotação/compactação/arquivamento só são testados na
    automação Ansible real (`ansible/`, `AWS.md`). Requer
    `mkdir -p data/logs data/textfile` antes do primeiro
    `docker compose up` (senão o Docker cria essas pastas como `root` e os
    serviços, rodando com `UID`/`GID` do host, não conseguem escrever
    nelas) — ver `docker/concentrador/README.md`.
- README na raiz (`README.md`) explica a arquitetura em alto nível e tem o
  passo a passo de como subir/testar tudo localmente.
- Detalhes de como rodar, testar e adicionar uma nova app estão nos READMEs
  de cada pasta (`docker/concentrador/README.md`, `apps/README.md`) —
  ler antes de mexer, para não repetir decisões (ex.: por que
  `--strict.perms=false` no Filebeat, por que copytruncate na rotação, por
  que `mkdir -p data/logs data/textfile` + `UID`/`GID` precisam vir antes
  do `docker compose up` do concentrador — sem isso `vector` e
  `textfile-collector` gravam essas pastas como `root` e o host não
  consegue ler/mover/apagar esses arquivos depois).
- Automação Ansible (`ansible/vector-provision.yml`, detalhes em `AWS.md`
  e em `ansible/README.md`) provisiona a EC2 concentradora real (Vector,
  node_exporter, textfile collector, logrotate, arquivamento) — validada de
  ponta a ponta direto contra uma EC2 real (Amazon Linux 2023), não só
  lida/revisada. Antes disso existir, tinha sido validada localmente sem
  conta AWS via `docker/local-ec2/` (container com systemd) e `vagrant/`
  (VM VirtualBox, box `bento/amazonlinux-2023`) — ambas as pastas foram
  removidas do repo depois que a validação passou a ser feita direto na
  EC2 real; os bugs reais que elas pegaram (ex. `findutils` faltando)
  continuam corrigidos no código (ver `AWS.md` para o histórico). Variáveis
  ficam em `ansible/group_vars/vector.yml` (não `vars/`) — carregadas
  automaticamente pelo grupo `[vector]` usado em `ansible/inventory/
  hosts.ini`, sem precisar de `-e` na linha de comando; arquivos da pasta
  `ansible/` não têm comentários internos, explicações ficam em
  `ansible/README.md`.
- `apps/`: 3 apps NestJS de teste rodando direto no host (sem Docker;
  `app1/`, `app2/`, `app3/`, cada uma sua própria pasta com `APP_NAME`
  fixo no código), cada uma escrevendo em `apps/<nome>/logs/<nome>.log`.
  `apps/filebeat/filebeat.yml` é a cópia versionada do config usado pelo
  Filebeat instalado no host (`/home/fabio/filebeat-9.5.1-linux-x86_64`),
  com um input por app, enviando para o Vector local de
  `docker/concentrador` (`localhost:5044`). Ainda não executado (nem o
  Filebeat nem as apps) — só o ambiente/instruções foram criados, ver
  `apps/README.md`. Bloqueio conhecido: **Node.js não está instalado
  neste host**.

## Próximo passo

- Teste de ponta a ponta pendente, a ser feito pelo usuário: 1) subir o
  Docker (`docker/concentrador`, agora com Vector + node-exporter +
  Prometheus + Grafana); 2) subir as 3 apps de `apps/` no host (requer
  instalar Node.js antes — **ainda não está instalado neste host**); 3)
  subir o Filebeat no host apontando para o Docker local (`localhost:5044`,
  já configurado em `apps/filebeat/filebeat.yml`). Confirmar que os logs
  chegam via rede real (não só o evento de teste sintético usado até
  agora) e que as apps aparecem no dashboard do Grafana
  (`http://localhost:3001`) depois da primeira varredura do
  `textfile-collector` (até 15 min).

Itens ainda em aberto (ver "Pendências conhecidas" em
`docker/concentrador/README.md`):
- Alertas no Grafana (thresholds já descritos em `arquitetura.md`, painéis
  já existem, mas nenhuma regra de alerta está configurada).
- Alerta de app individual crescendo com taxa anormal (fora de escopo por
  decisão já registrada em `arquitetura.md` § Métricas).
- TLS entre Filebeat e Vector (adiado por decisão de arquitetura).

## Convenção

Manter este arquivo atualizado conforme o projeto avança (decisões novas,
estado atual, próximos passos), para que o contexto siga o repositório em
qualquer máquina só com `git pull`.
