# Ansible

Provisiona (ou atualiza) a EC2 concentradora de logs: Vector, rotação
(logrotate), arquivamento e métricas (node_exporter + textfile collector).
A instância já precisa existir (Amazon Linux 2023) e já ter o volume EBS
montado — isso é responsabilidade de quem provisiona a infraestrutura, não
deste playbook.

Contexto de arquitetura completo (por que Vector, por que sem TLS, diagrama
do fluxo cliente → concentradora) em [`../AWS.md`](../AWS.md) — este README
cobre só o funcionamento interno da automação.

## Estrutura

```
ansible/
├── vector-provision.yml         # playbook único, só declara a ordem das roles
├── group_vars/vector.yml        # variáveis do grupo "vector" — carregadas automaticamente
├── inventory/
│   ├── hosts.ini                 # inventário de exemplo para uma EC2 real
│   ├── local-ec2.ini              # inventário do container docker/local-ec2
│   └── vagrant.ini                # inventário da VM vagrant/
└── roles/
    ├── common/               # pacotes base, usuário/grupo "vector", valida o mount do EBS
    ├── vector/                # binário + config + systemd do Vector, cria .../logs
    ├── node_exporter/         # binário + systemd do node_exporter, cria o dir do textfile collector
    ├── textfile_collector/    # log-metrics.sh + timer de 15 em 15 min
    ├── logrotate/             # logrotate-vector.conf + timer de hora em hora
    └── archive_logs/          # archive-logs.sh + timer diário, cria .../archive
```

## Variáveis (`group_vars/vector.yml`)

Como todas as três inventories (`hosts.ini`, `local-ec2.ini`, `vagrant.ini`)
usam o mesmo grupo `[vector]`, o Ansible carrega `group_vars/vector.yml`
automaticamente para qualquer uma delas — não é preciso passar `-e` na
linha de comando. Para editar uma variável (ex. atualizar a versão do
Vector), basta editar este arquivo e rodar o playbook de novo.

| Variável | Uso |
|---|---|
| `aws_region`, `aws_vpc_id`, `aws_subnet_id`, `aws_security_group_id`, `aws_instance_id` | Só documentação/referência do ambiente — nenhuma task chama a API da AWS com esses valores. A instância já existe, já tem o EBS montado, e o IP é usado só no inventário (SSH). |
| `vector_system_user`, `vector_system_group` | Usuário/grupo de sistema dono dos processos e dos dados (Vector, node_exporter, textfile collector). |
| `vector_data_root` | Caminho onde o EBS já está montado (fora do escopo do Ansible). A role `common` valida no início do playbook que é de fato um ponto de montagem — falha cedo em vez de gravar sem querer no disco raiz. |
| `vector_ebs_device` | Só para referência/conferência manual (`lsblk`/`df`) — nenhuma task usa este valor. |
| `vector_version`, `vector_target` | Versão do Vector e plataforma do release a baixar. Use `aarch64-unknown-linux-musl` em instâncias Graviton. |
| `vector_listen_port` | Porta onde o Vector escuta o protocolo Logstash/Beats (Filebeat dos clientes). |
| `node_exporter_version`, `node_exporter_arch` | Versão do node_exporter e arquitetura do release. Use `arm64` em instâncias Graviton. |
| `node_exporter_port` | Porta de scrape do Prometheus. |
| `textfile_collector_dir` | Diretório lido pelo node_exporter (`--collector.textfile.directory`) onde `log-metrics.sh` escreve as métricas custom. |
| `metrics_interval_seconds` | Intervalo do timer que roda `log-metrics.sh` (900s = 15 min, igual ao ambiente Docker). |
| `log_archive_retention_days` | Dias de retenção antes do `archive-logs.sh` mover um `.gz` para `.../archive`. |

## O que o playbook faz

Idempotente — rodar de novo (ex. depois de mudar `vector_version` em
`group_vars/vector.yml`) atualiza só o que mudou e reinicia só os serviços
afetados. A ordem das roles em `vector-provision.yml` importa — elas não
são independentes:

1. **`common`**: confirma que `vector_data_root` já é um ponto de montagem
   real (`ansible_facts['mounts']`); instala pacotes base (`tar`, `gzip`,
   `findutils` — este último não vem por padrão em toda instalação mínima
   de AL2023, e é usado por `log-metrics.sh`/`archive-logs.sh`); cria
   usuário/grupo de sistema `vector`.
2. **`vector`**: cria `{{ vector_data_root }}/logs`; baixa e instala o
   Vector (binário do release oficial, versionado — symlink
   `/usr/local/bin/vector` apontando pra versão corrente, troca limpa ao
   atualizar `vector_version`); gera `/etc/vector/vector.yaml` e a unit
   systemd; habilita e sobe o serviço. Precisa rodar antes de
   `textfile_collector`, `logrotate` e `archive_logs` (todas leem/escrevem
   em `.../logs`).
3. **`node_exporter`**: cria `{{ textfile_collector_dir }}`; baixa e
   instala o `node_exporter`; unit systemd; habilita e sobe. Precisa rodar
   antes de `textfile_collector`.
4. **`textfile_collector`**: instala `log-metrics.sh` + unit/timer de 15
   em 15 min.
5. **`logrotate`**: instala o pacote `logrotate`; gera
   `/etc/vector/logrotate-vector.conf` e a unit/timer que o invoca de hora
   em hora.
6. **`archive_logs`**: cria `{{ vector_data_root }}/archive`; instala
   `archive-logs.sh` e o timer diário de arquivamento.

## O que **não** faz

- **Não mexe no volume EBS**: não anexa, não formata, não monta — assume
  que a instância já sobe com `vector_data_root` montado.
- **Não chama a API da AWS**: os `aws_*` em `group_vars/vector.yml` são só
  documentação do ambiente — o Ansible só faz SSH na instância e mexe no
  SO. Segurança de rede (liberar 5044/9100 no Security Group) é gerenciada
  fora deste playbook.
- **Não descobre nada sozinho**: sem inventário dinâmico, sem lookup de
  instância por tag — o IP é fornecido (inventário ou `-i "IP,"`).

## Detalhes técnicos (gotchas descobertos testando de verdade)

- **`vector-logrotate.service`** roda como `root` de propósito: a diretiva
  `su {{ vector_system_user }} {{ vector_system_group }}` dentro de
  `logrotate-vector.conf` exige que o logrotate tenha sido iniciado como
  root para poder trocar de usuário nas operações de arquivo — ele mesmo
  faz o drop de privilégio por dentro.
- **`--force`** no `ExecStart` do mesmo service é necessário: sem uma
  diretiva de frequência (`daily`/`weekly`) no `.conf`, o logrotate cai no
  critério padrão de tamanho (~1 MiB) em vez de girar a cada execução —
  testado que, sem `--force`, um log pequeno nunca rotaciona mesmo rodando
  o timer de hora em hora. `--force` ignora esse critério (mas ainda
  respeita `notifempty`, então apps sem log novo não geram `.gz` vazio).
- **`rotate 100000`** em `logrotate-vector.conf.j2`: `copytruncate` +
  `dateext` sem uma diretiva `rotate N` explícita falha silenciosamente
  (pula a cópia, gera erro tentando comprimir um arquivo que nunca foi
  criado). O número é só uma trava de segurança bem folgada — quem decide
  apagar (na prática, mover para `.../archive`) é o `archive-logs.sh`, não
  o logrotate.
- **Path glob dinâmico** em `logrotate-vector.conf.j2`
  (`.../logs/*/*/*/*.log`): cobre qualquer app/data/instância que já
  exista, inclusive apps novas, sem precisar de nenhuma alteração aqui —
  resolvido a cada execução do logrotate.
- **`log-metrics.sh`** e **`archive-logs.sh`** escaneiam os diretórios
  existentes a cada execução — uma app nova aparece nas métricas e no
  arquivamento sozinha, sem precisar reconfigurar nada.

## Compatibilidade

Só usa módulos builtin estáveis há vários anos (`dnf`, `user`, `group`,
`file`, `template`, `unarchive`, `systemd`, `assert`) — sem depender de
nenhuma collection externa. Testado com `ansible-core` 2.21
(`--syntax-check` limpo).

Os módulos são chamados pelo nome curto (`file`, `template`, ...), sem o
prefixo `ansible.builtin.` — funciona igual, o Ansible resolve módulos
builtin por nome curto desde sempre. A única diferença prática: o
`ansible-lint` no profile `production` exige FQCN (`ansible.builtin.file`
etc.) e reclama sem ele — rodando aqui sem o prefixo, o lint cai pro
profile `shared` (avisos de estilo `fqcn`, nada funcional). Se `production`
for importante pro time, é só voltar o prefixo.

## Como rodar

```bash
cd ansible

# opção A: editar o IP em inventory/hosts.ini, depois
ansible-playbook -i inventory/hosts.ini vector-provision.yml

# opção B: sem editar nada, IP direto na linha de comando
ansible-playbook -i "<IP_DA_EC2>," vector-provision.yml \
  -u ec2-user --private-key ~/.ssh/minha-chave.pem
```

Não é preciso passar `-e @group_vars/vector.yml` — o Ansible carrega
`group_vars/<nome-do-grupo>.yml` automaticamente para hosts do grupo
`[vector]`, em qualquer uma das três inventories.

Pré-requisitos: chave SSH com acesso `ec2-user` na instância, Security
Group liberando 22/tcp de onde o Ansible roda, e o volume EBS já montado em
`vector_data_root` (o playbook falha no primeiro task se não estiver).

## Testando localmente, sem AWS

[`../docker/local-ec2/`](../docker/local-ec2/) sobe um container com Amazon
Linux 2023 de verdade (`systemd` como init, `sshd` ativo) e roda
`vector-provision.yml` contra ele:

```bash
cd docker/local-ec2
./test.sh
```

[`../vagrant/`](../vagrant/) faz o mesmo numa VM VirtualBox de verdade (box
`bento/amazonlinux-2023`) em vez de container:

```bash
cd vagrant
./test.sh
```

Detalhes de cada ambiente de teste nos READMEs das respectivas pastas.
