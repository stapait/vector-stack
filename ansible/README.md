# Ansible

Provisiona (ou atualiza) a EC2 concentradora de logs: tuning de SO para alta carga, Vector, rotação (logrotate), arquivamento e métricas (node_exporter + textfile collector). A instância já precisa existir (Amazon Linux 2023) e já ter o volume EBS montado — isso é responsabilidade de quem provisiona a infraestrutura, não deste playbook.

Contexto de arquitetura completo (por que Vector, por que sem TLS, diagrama do fluxo cliente → concentradora) em [`../AWS.md`](../AWS.md) — este README cobre só o funcionamento interno da automação.

## Estrutura

```
ansible/
├── vector-provision.yml         # playbook único, só declara a ordem das roles
├── group_vars/vector.yml        # variáveis do grupo "vector" — carregadas automaticamente
├── inventory/
│   └── hosts.ini                 # inventário de exemplo para uma EC2 real
└── roles/
    ├── os_tuning/            # sysctl (rede, memória, disco) para alta carga
    ├── common/               # pacotes base, usuário/grupo "vector", valida o mount do EBS
    ├── vector/                # binário + config + systemd do Vector, cria .../logs e .../state
    ├── node_exporter/         # binário + systemd do node_exporter, cria o dir do textfile collector
    ├── textfile_collector/    # log-metrics.sh + timer de 15 em 15 min
    ├── logrotate/             # logrotate-vector.conf + timer de hora em hora
    └── archive_logs/          # archive-logs.sh + timer diário, cria .../archive
```

## Variáveis (`group_vars/vector.yml`)

Como `hosts.ini` usa o grupo `[vector]`, o Ansible carrega `group_vars/vector.yml` automaticamente — não é preciso passar `-e` na linha de comando. Para editar uma variável (ex. atualizar a versão do Vector), basta editar este arquivo e rodar o playbook de novo.

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
| `os_tuning_vm_swappiness` | Quão agressivo o kernel é para trocar memória por swap (0-100). `1` evita swap salvo pressão extrema — importante porque, sob memória apertada, um host que começa a fazer swap fica lento por inteiro (não só o processo com pressão), a ponto de exigir reboot. |
| `os_tuning_vm_dirty_background_ratio`, `os_tuning_vm_dirty_ratio` | % da RAM que pode ficar como página suja (ainda não gravada em disco) antes do kernel começar a escrever em background (`dirty_background_ratio`) ou bloquear escritores até liberar (`dirty_ratio`). Baixados dos ~10/20% padrão porque esta máquina escreve log o tempo todo — deixar acumular muita página suja significa um flush gigante e súbito depois, que trava I/O justo quando mais chega log. |
| `os_tuning_fs_file_max` | Teto de file descriptors abertos simultaneamente **no sistema inteiro** (não confundir com o limite por processo, que é `vector_limit_nofile`). Precisa ser maior que qualquer `LimitNOFILE` de serviço individual. |
| `os_tuning_net_somaxconn`, `os_tuning_net_tcp_max_syn_backlog` | Tamanho da fila de conexões TCP pendentes de aceitar/handshake. Com 50+ Filebeats reconectando ao mesmo tempo (deploy, restart do Vector, blip de rede), o valor padrão do kernel (128) é pequeno demais e causa conexões recusadas/retry. |
| `os_tuning_net_netdev_max_backlog` | Fila de pacotes de rede recebidos aguardando o kernel processar, antes de chegar à aplicação — evita descarte de pacote sob rajada de tráfego. |
| `os_tuning_net_rmem_max`, `os_tuning_net_wmem_max` | Teto de buffer de recepção/envio por socket TCP — usado também para compor `tcp_rmem`/`tcp_wmem` (mín/padrão/máx) no template. Relevante para sustentar throughput alto com muitas conexões simultâneas sem o kernel limitar a janela TCP. |
| `vector_limit_nofile` | `LimitNOFILE` da unit systemd do Vector — file descriptors abertos só por ele. O Vector mantém um arquivo aberto por combinação ativa de app/dia/instância (ver `arquitetura.md` § Métricas), então isso cresce com o número de apps/instâncias enviando log ao mesmo tempo. |
| `vector_connection_limit` | Máximo de conexões TCP simultâneas aceitas pelo source `logstash` do Vector — uma por Filebeat cliente conectado. |
| `vector_receive_buffer_bytes` | Tamanho do buffer de recepção (`SO_RCVBUF`) por conexão do source `logstash`. |
| `vector_sink_buffer_max_size` | Tamanho do buffer em disco do sink `file` (bytes) — absorve picos de escrita sem aplicar backpressure imediata nos Filebeats conectados. Mínimo aceito pelo Vector para buffer em disco é ~256MB; o buffer é gravado em `data_dir` (`{{ vector_data_root }}/state`, criado pela role `vector`). |

## O que o playbook faz

Idempotente — rodar de novo (ex. depois de mudar `vector_version` em `group_vars/vector.yml`) atualiza só o que mudou e reinicia só os serviços afetados. A ordem das roles em `vector-provision.yml` importa — elas não são independentes:

1. **`os_tuning`**: gera `/etc/sysctl.d/99-vector-concentrador.conf` (swappiness, dirty ratio, backlog de conexão, buffers de socket — ver tabela de variáveis acima) e aplica com `sysctl --system`. Roda primeiro porque é tuning de SO independente de qualquer outro serviço, e o Vector já deve subir sob os parâmetros finais.
2. **`common`**: confirma que `vector_data_root` já é um ponto de montagem real (`ansible_facts['mounts']`); instala pacotes base (`tar`, `gzip`, `findutils` — este último não vem por padrão em toda instalação mínima de AL2023, e é usado por `log-metrics.sh`/`archive-logs.sh`); cria usuário/grupo de sistema `vector`.
3. **`vector`**: cria `{{ vector_data_root }}/logs` e `{{ vector_data_root }}/state` (usado por `data_dir`, onde o Vector persiste o buffer em disco do sink); baixa e instala o Vector (binário do release oficial, versionado — symlink `/usr/local/bin/vector` apontando pra versão corrente, troca limpa ao atualizar `vector_version`); gera `/etc/vector/vector.yaml` e a unit systemd; habilita e sobe o serviço. Precisa rodar antes de `textfile_collector`, `logrotate` e `archive_logs` (todas leem/escrevem em `.../logs`).
4. **`node_exporter`**: cria `{{ textfile_collector_dir }}`; baixa e instala o `node_exporter`; unit systemd; habilita e sobe. Precisa rodar antes de `textfile_collector`.
5. **`textfile_collector`**: instala `log-metrics.sh` + unit/timer de 15 em 15 min.
6. **`logrotate`**: instala o pacote `logrotate`; gera `/etc/vector/logrotate-vector.conf` e a unit/timer que o invoca de hora em hora.
7. **`archive_logs`**: cria `{{ vector_data_root }}/archive`; instala `archive-logs.sh` e o timer diário de arquivamento.

## O que **não** faz

- **Não mexe no volume EBS**: não anexa, não formata, não monta — assume que a instância já sobe com `vector_data_root` montado.
- **Não chama a API da AWS**: os `aws_*` em `group_vars/vector.yml` são só documentação do ambiente — o Ansible só faz SSH na instância e mexe no SO. Segurança de rede (liberar 5044/9100 no Security Group) é gerenciada fora deste playbook.
- **Não descobre nada sozinho**: sem inventário dinâmico, sem lookup de instância por tag — o IP é fornecido (inventário ou `-i "IP,"`).

## Tuning para alta carga (produção)

Pensado para uma concentradora recebendo de muitas fontes ao mesmo tempo (dezenas de instâncias/containers enviando log simultaneamente), dois níveis de ajuste:

- **SO (role `os_tuning`)**: sysctl de rede (fila de conexão/handshake TCP, buffers de socket, backlog de pacote) e de memória/disco (`swappiness` baixo, `dirty_ratio`/`dirty_background_ratio` reduzidos para não deixar acumular uma escrita gigante e súbita num host que grava log o tempo todo). Ver a tabela de variáveis acima para o racional de cada valor.
- **Vector (role `vector`)**: `LimitNOFILE` da unit systemd elevado (o Vector mantém um arquivo aberto por combinação ativa de app/dia/instância — cresce com o número de fontes simultâneas, ver `arquitetura.md` § Métricas), `connection_limit`/`receive_buffer_bytes` no source `logstash`, e um **buffer em disco** (`buffer.type: disk`) no sink `file` — absorve picos de escrita sem aplicar backpressure imediata nos Filebeats conectados. Por ser Rust sem garbage collector, o Vector não tem o modo de falha de "GC longo → fila trava → conexões se acumulam" que existe em coletores baseados em JVM sob carga alta (ver `README.md` § "Por que Vector, e não Logstash" na raiz do repo).

**Ainda não validado end-to-end contra a EC2 real** (diferente do resto do playbook, ver "Validação" abaixo) — os valores vêm de práticas gerais de tuning de Linux/Vector para ingestão de log em alta carga, não de um incidente reproduzido nesta automação. Vale re-rodar o playbook e observar o comportamento (`sysctl -a`, `systemctl status vector`, `journalctl -u vector`, e o dashboard "Concentrador - Saúde da Instância" do Grafana) numa carga real antes de considerar esses valores definitivos.

## Detalhes técnicos (gotchas descobertos testando de verdade)

- **`vector-logrotate.service`** roda como `root` de propósito: a diretiva `su {{ vector_system_user }} {{ vector_system_group }}` dentro de `logrotate-vector.conf` exige que o logrotate tenha sido iniciado como root para poder trocar de usuário nas operações de arquivo — ele mesmo faz o drop de privilégio por dentro.
- **`--force`** no `ExecStart` do mesmo service é necessário: sem uma diretiva de frequência (`daily`/`weekly`) no `.conf`, o logrotate cai no critério padrão de tamanho (~1 MiB) em vez de girar a cada execução — testado que, sem `--force`, um log pequeno nunca rotaciona mesmo rodando o timer de hora em hora. `--force` ignora esse critério (mas ainda respeita `notifempty`, então apps sem log novo não geram `.gz` vazio).
- **`rotate 100000`** em `logrotate-vector.conf.j2`: `copytruncate` + `dateext` sem uma diretiva `rotate N` explícita falha silenciosamente (pula a cópia, gera erro tentando comprimir um arquivo que nunca foi criado). O número é só uma trava de segurança bem folgada — quem decide apagar (na prática, mover para `.../archive`) é o `archive-logs.sh`, não o logrotate.
- **Path glob dinâmico** em `logrotate-vector.conf.j2` (`.../logs/*/*/*/*.log`): cobre qualquer app/data/instância que já exista, inclusive apps novas, sem precisar de nenhuma alteração aqui — resolvido a cada execução do logrotate.
- **`log-metrics.sh`** e **`archive-logs.sh`** escaneiam os diretórios existentes a cada execução — uma app nova aparece nas métricas e no arquivamento sozinha, sem precisar reconfigurar nada.

## Compatibilidade

Só usa módulos builtin estáveis há vários anos (`dnf`, `user`, `group`, `file`, `template`, `unarchive`, `systemd`, `assert`, `command`) — sem depender de nenhuma collection externa. Testado com `ansible-core` 2.21 (`--syntax-check` limpo).

Os módulos são chamados pelo nome curto (`file`, `template`, ...), sem o prefixo `ansible.builtin.` — funciona igual, o Ansible resolve módulos builtin por nome curto desde sempre. A única diferença prática: o `ansible-lint` no profile `production` exige FQCN (`ansible.builtin.file` etc.) e reclama sem ele — rodando aqui sem o prefixo, o lint cai pro profile `shared` (avisos de estilo `fqcn`, nada funcional). Se `production` for importante pro time, é só voltar o prefixo.

## Como rodar

```bash
cd ansible

# opção A: editar o IP em inventory/hosts.ini, depois
ansible-playbook -i inventory/hosts.ini vector-provision.yml

# opção B: sem editar nada, IP direto na linha de comando
ansible-playbook -i "<IP_DA_EC2>," vector-provision.yml \
  -u ec2-user --private-key ~/.ssh/minha-chave.pem
```

Não é preciso passar `-e @group_vars/vector.yml` — o Ansible carrega `group_vars/<nome-do-grupo>.yml` automaticamente para hosts do grupo `[vector]`.

Pré-requisitos: chave SSH com acesso `ec2-user` na instância, Security Group liberando 22/tcp de onde o Ansible roda, e o volume EBS já montado em `vector_data_root` (o playbook falha no primeiro task se não estiver).

## Validação

Validado de ponta a ponta direto contra uma EC2 real — não só lida/ revisada. Antes disso existir, foi validado localmente sem conta AWS (container com Amazon Linux 2023 e depois uma VM VirtualBox com a mesma imagem); esse ambiente de teste local foi removido do repo depois que a validação passou a ser feita direto na EC2 real. Detalhes e os bugs reais que essa validação local pegou (ex. `findutils` faltando) em [`../AWS.md`](../AWS.md).
