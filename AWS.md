# Deploy na AWS

Este documento descreve o deploy da arquitetura de centralização de logs
(ver [`arquitetura.md`](./arquitetura.md)) num ambiente real de teste na
AWS — separado do ambiente local Docker (documentado em
[`README.md`](./README.md) e [`CLAUDE.md`](./CLAUDE.md), que continuam
focados só em Docker).

## 1. Arquitetura

Uma única EC2 concentradora roda o Vector e recebe logs de N clientes — EC2
"normais" ou containers Nomad — cada um enviando via Filebeat. Do lado do
cliente nada muda em relação ao que já foi validado localmente: mesmo
Filebeat, mesmos campos `app`/`instance`, mesmo protocolo (Beats/Logstash)
na porta 5044.

```
[Cliente 1: EC2]                [Cliente 2: task Nomad]        [Cliente N: ...]
  App -> log local                App -> log local               App -> log local
  Filebeat                        Filebeat                        Filebeat
  fields.app = "orders-app"       fields.app = "payments-app"     fields.app = "..."
  fields.instance = i-0abc123     fields.instance = alloc-xyz     fields.instance = ...
       |                                |                               |
       |  output.logstash: vector.interno:5044 (TCP, sem TLS por ora)   |
       +--------------------------------+-------------------------------+
                                         |
                                         v
                    ======================================
                    |  EC2 concentradora (Amazon Linux 2023)  |
                    |                                          |
                    |  [Vector]  source logstash:5044          |
                    |    sink file -> /mnt/vector/logs/{app}/   |
                    |               {YYYY-MM-DD}/{instancia}/   |
                    |               {app}.log  (arquivo atual)  |
                    |                                          |
                    |  [logrotate, timer de hora em hora]       |
                    |    {app}.log -> {app}-{HH}.log.gz         |
                    |                                          |
                    |  [archive-logs.sh, timer diário]          |
                    |    .gz com +30 dias -> /mnt/vector/archive/{app}/... |
                    |                                          |
                    |  [node_exporter :9100/metrics]            |
                    |    + textfile collector (tamanho/última   |
                    |      escrita por app, gerado a cada 15min)|
                    |                                          |
                    |  Volume EBS montado em /mnt/vector         |
                    |  (fora do escopo deste playbook)          |
                    ======================================
                                         |
                                         v
                       Prometheus (já existente) faz scrape
                       Grafana (já existente) exibe dashboards
```

Ponto central do design, que se mantém igual ao ambiente local: **a EC2 do
Vector é intocável** depois de provisionada. Uma aplicação nova só precisa
rodar um Filebeat configurado corretamente — nenhuma mudança na
concentradora, seja no Vector, no logrotate (path glob dinâmico) ou nas
métricas (script escaneia os diretórios existentes a cada execução).

IP fixo ou DNS interno (a definir qual dos dois pelo time de infra) é o que
os clientes usam em `output.logstash.hosts` — o Ansible não gerencia
Route53/Elastic IP, só assume que existe um endereço estável para colocar
nessa config.

## 2. Recursos necessários

### 2.1 Vector (EC2 concentradora)

| Recurso | Detalhe |
|---|---|
| SO | Amazon Linux 2023 |
| Binário Vector | versão `0.43.0` por padrão (`vector_version` em `vars/vector.yml`), baixado do release oficial, roda como serviço systemd |
| Usuário dedicado | `vector` (system user, sem shell), dono dos dados e dos processos |
| Volume de dados | EBS montado em `/mnt/vector` **antes** do provisionamento (fora do escopo do Ansible — ver seção 3) |
| Estrutura de pastas | `/mnt/vector/logs/{app}/{YYYY-MM-DD}/{instancia}/{app}.log` (atual) e `/mnt/vector/archive/{app}/{YYYY-MM-DD}/{instancia}/{app}-{HH}.log.gz` (arquivado após 30 dias) |
| Rotação | `logrotate` com um path glob (`/mnt/vector/logs/*/*/*/*.log`), disparado por um `systemd timer` próprio de hora em hora — cobre apps novas automaticamente, sem precisar de configuração por app |
| Arquivamento | Script `archive-logs.sh`, `systemd timer` diário, move `.gz` com mais de 30 dias mantendo a estrutura |
| Métricas | `node_exporter` (porta 9100) + script `log-metrics.sh` (textfile collector, a cada 15 min) — gera `log_app_disk_bytes` e `log_app_last_write_timestamp_seconds` por app, também dinâmico |
| Rede (inbound) | 5044/tcp (Filebeat dos clientes) e 9100/tcp (scrape do Prometheus) — via Security Group, fora do escopo do Ansible (ver seção 3) |
| Prometheus/Grafana | Já existem — só apontar um novo target `{ip-da-concentradora}:9100` no Prometheus; nada a instalar aqui |

### 2.2 Apps clientes

| Recurso | Detalhe |
|---|---|
| Filebeat | Instalado na EC2 ou, em Nomad, rodando no mesmo container/task da app (mesmo padrão já validado no `docker/apps` local) |
| Configuração | Só os campos `fields.app` e `fields.instance`, e `output.logstash.hosts` apontando pro IP/DNS da concentradora, porta 5044 (ver seção 4) |
| Rede (outbound) | Acesso à porta 5044/tcp da concentradora — via Security Group/rede |
| Nada mais | Não precisa de nenhum agente adicional, nem de tocar na concentradora para começar a enviar logs |

## 3. Provisionamento com Ansible

Tudo em [`ansible/`](./ansible/), organizado em roles — uma por
responsabilidade:

```
ansible/
├── vector-provision.yml         # playbook único, só declara a ordem das roles
├── inventory/hosts.ini          # 1 host (edite o IP, ou passe -i "IP," na linha de comando)
├── vars/vector.yml              # arquivo único de variáveis (compartilhado por todas as roles)
└── roles/
    ├── common/              # pacotes base, usuário/grupo "vector", valida o mount do EBS
    ├── vector/               # binário + config + systemd do Vector, cria .../logs
    ├── node_exporter/        # binário + systemd do node_exporter, cria o dir do textfile collector
    ├── textfile_collector/   # log-metrics.sh + timer de 15 em 15 min
    ├── logrotate/            # logrotate-vector.conf + timer de hora em hora
    └── archive_logs/         # archive-logs.sh + timer diário, cria .../archive
```

### O que o playbook faz

Idempotente — rodar de novo (ex. depois de mudar `vector_version` em
`vars/vector.yml`) atualiza só o que mudou e reinicia só os serviços
afetados. A ordem das roles em `vector-provision.yml` importa — elas não
são independentes:

1. **`common`**: confirma que `vector_data_root` (`/mnt/vector`) já é um
   ponto de montagem real (`ansible_facts['mounts']`) — falha cedo com uma
   mensagem clara se não for, em vez de gravar sem querer no disco raiz da
   instância; instala pacotes base (`tar`, `gzip`); cria usuário/grupo de
   sistema `vector`.
2. **`vector`**: cria `/mnt/vector/logs`; baixa e instala o Vector (binário
   do release oficial, versionado — symlink `/usr/local/bin/vector`
   apontando pra versão corrente, troca limpa ao atualizar
   `vector_version`); gera `/etc/vector/vector.yaml` e a unit systemd;
   habilita e sobe o serviço. Precisa rodar antes de `textfile_collector`,
   `logrotate` e `archive_logs` (todas leem/escrevem em
   `.../logs`).
3. **`node_exporter`**: cria o diretório do textfile collector; baixa e
   instala o `node_exporter`; unit systemd; habilita e sobe. Precisa rodar
   antes de `textfile_collector`.
4. **`textfile_collector`**: script `log-metrics.sh` + unit/timer de 15 em
   15 min.
5. **`logrotate`**: instala o pacote `logrotate`; gera
   `/etc/vector/logrotate-vector.conf` e a unit/timer que o invoca de hora
   em hora.
6. **`archive_logs`**: cria `/mnt/vector/archive`; instala
   `archive-logs.sh` e o timer diário de arquivamento.

### O que **não** faz (por decisão, ver histórico da conversa)

- **Não mexe no volume EBS**: não anexa, não formata, não monta — assume
  que a instância já sobe com `/mnt/vector` montado (responsabilidade do
  provisionamento de infraestrutura, fora do Ansible). `vars/vector.yml`
  tem um campo `vector_ebs_device` só para referência/conferência manual
  (`lsblk`/`df`), nenhuma task usa esse valor.
- **Não chama a API da AWS**: os IDs (`aws_vpc_id`, `aws_subnet_id`,
  `aws_security_group_id`, `aws_instance_id`) ficam em `vars/vector.yml`
  como documentação central do ambiente, não como entrada de nenhuma task —
  o Ansible só faz SSH na instância e mexe no SO. Segurança de rede
  (liberar 5044/9100 no Security Group) é gerenciada fora deste playbook.
- **Não descobre nada sozinho**: sem inventário dinâmico, sem lookup de
  instância por tag — o IP é fornecido (inventário ou `-i "IP,"`).

### Compatibilidade

Só usa módulos builtin estáveis há vários anos (`dnf`, `user`, `group`,
`file`, `template`, `unarchive`, `systemd`, `assert`) — sem depender de
nenhuma collection externa nem de recurso exclusivo das últimas releases do
Ansible. Testado com `ansible-core` 2.21 (`--syntax-check` limpo).

Os módulos são chamados pelo nome curto (`file`, `template`, ...), sem o
prefixo `ansible.builtin.` — funciona igual, o Ansible resolve módulos
builtin por nome curto desde sempre. A única diferença prática: o
`ansible-lint` no profile `production` exige FQCN (`ansible.builtin.file`
etc.) e reclama sem ele — rodando aqui sem o prefixo, o lint cai pro
profile `shared` (34 avisos de estilo `fqcn`, nada funcional). Se
`production` for importante pro time, é só voltar o prefixo.

### Como rodar

```bash
cd ansible

# opção A: editar o IP em inventory/hosts.ini, depois
ansible-playbook -i inventory/hosts.ini vector-provision.yml \
  -e @vars/vector.yml

# opção B: sem editar nada, IP direto na linha de comando
ansible-playbook -i "<IP_DA_EC2>," vector-provision.yml \
  -u ec2-user --private-key ~/.ssh/minha-chave.pem \
  -e @vars/vector.yml
```

Pré-requisitos: chave SSH com acesso `ec2-user` na instância, Security
Group liberando 22/tcp de onde o Ansible roda, e o volume EBS já montado em
`/mnt/vector` (o playbook falha no primeiro task se não estiver).

### Nota sobre o logrotate (decisões descobertas testando de verdade)

Duas pegadinhas do `logrotate` que só apareceram testando o config
gerado, e que valem registrar porque não são óbvias lendo a documentação:

- Sem uma diretiva de frequência (`daily`/`weekly`) — necessário aqui, já
  que rotação horária não existe nativamente no logrotate —, ele cai no
  critério padrão de **tamanho** (~1 MiB) em vez de rotacionar a cada
  execução. Por isso o serviço roda `logrotate --force`, que ignora esse
  critério (mas ainda respeita `notifempty`, então apps sem log novo desde
  a última rotação não geram `.gz` vazio).
- `copytruncate` + `dateext` **sem** uma diretiva `rotate N` explícita
  falha silenciosamente (pula a cópia, gera um erro tentando comprimir um
  arquivo que nunca foi criado). Por isso o config tem `rotate 100000` — um
  número alto só para nunca bater no limite, já que quem decide apagar (na
  prática, mover para `/archive`) é o `archive-logs.sh`, não o logrotate.

## 4. Configurando um cliente

Uma aplicação nova só precisa de duas coisas: escrever seu log num arquivo
local, e rodar um Filebeat apontando pra esse arquivo. Nenhuma mudança do
lado da concentradora.

```yaml
# /etc/filebeat/filebeat.yml (na EC2 cliente, ou dentro do container/task Nomad)
filebeat.inputs:
  - type: log
    paths:
      - /var/log/minha-app/*.log
    fields:
      app: minha-app                 # vira o nome da pasta em /mnt/vector/logs/
      instance: ${INSTANCE_ID}       # hostname, EC2 instance-id, ou Nomad alloc ID
    fields_under_root: false

output.logstash:
  hosts: ["vector.interno:5044"]     # IP fixo ou DNS da concentradora
```

- `fields.app` é o único campo que precisa ser exclusivo por aplicação —
  vira literalmente o nome da pasta em `/mnt/vector/logs/`. Duas apps
  usando o mesmo valor de `app` teriam os logs misturados na mesma pasta.
- `instance` identifica a origem dentro da mesma app (várias EC2/tasks
  rodando a mesma app) — hostname, EC2 instance-id (`$(ec2-metadata
  --instance-id)` ou variável de ambiente já injetada) ou `NOMAD_ALLOC_ID`
  em containers Nomad, o mesmo padrão já usado no `arquitetura.md` e no
  ambiente Docker local.
- **Acesso de rede necessário**: porta **5044/tcp** de saída do cliente
  até a concentradora (Security Group da concentradora precisa liberar
  entrada nessa porta a partir da subnet/SG dos clientes). Sem TLS nesta
  fase — mesma decisão já registrada em `arquitetura.md` (rede privada
  considerada confiável por ora).
- Depois de configurado, `systemctl enable --now filebeat` (ou o
  equivalente na imagem do container Nomad) — em segundos os logs devem
  aparecer em `/mnt/vector/logs/minha-app/.../minha-app.log` na
  concentradora, sem precisar reiniciar nem reconfigurar o Vector.
