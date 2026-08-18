# Arquitetura de Centralização de Logs

## Objetivo

Centralizar logs de texto de múltiplas aplicações (rodando em instâncias EC2 e containers Nomad) em uma máquina concentradora, organizados em filesystem por aplicação, dia, instância e hora — com acompanhamento em tempo real e adição de novas aplicações sem alterações no lado do servidor.

## Requisitos (recapitulando)

1. Acompanhar logs de todas as instâncias em tempo real na máquina concentradora.
2. Compatível com Filebeat.
3. Fácil adicionar uma nova aplicação — idealmente zero mudança no servidor, bastando a aplicação/instância enviar no formato certo.
4. Suportar instâncias EC2 e containers (Nomad).
5. Rotacionamneto de logs. Uma vez a cada hora, o log atual é movido para um log com o sufixo -{hora}.log e mantido separadamente, equanto que um novo .log é gerado. Esse log antigo deve ser compactado com extensão .gz
6. Após um período de 30 dias, os logs .gz deverão ser movidos para uma pasta /archive dentro da pasta de logs do filesystem do vector, mantendo a mesma estrutura. A ideia é deixar na pasta principal apenas os logs mais novos.

## Decisões

| Tópico | Decisão |
|---|---|
| Transporte / agregador na concentradora | **Vector** (não Logstash) |
| Identificação de app/instância | **Campos fixos no Filebeat** (`fields`) |
| Tempo real | **`tail -f` / `multitail`** direto nos arquivos |
| Retenção | Padrão inicial de **30 dias**, ajustável depois |
| Onde roda a concentradora | **EC2 dedicada** |
| Segurança em trânsito | **Sem TLS por enquanto** (rede privada / VPC) |
| Métricas | **node_exporter** na concentradora, scrape por **Prometheus já existente**, dashboards + alertas no **Grafana** |
| Escopo do monitoramento | Apenas a **EC2 concentradora** (não as instâncias de origem, por ora) |
| Tamanho por app | Métrica custom via **textfile collector**, atualizada a cada **15 min (configurável)** |

## Visão geral do fluxo

```
[App] --escreve--> [arquivo de log local]
                          |
                          v
                    [Filebeat local]
                    fields.app = "customers-app"
                    fields.instance = "i-0abc123" (ou task Nomad)
                          |
                          |  output: vector / lumberjack (porta 5044-like)
                          v
              ============================
              |   EC2 Concentradora       |
              |                           |
              |   [Vector]                |
              |     source: filebeat/logstash listener |
              |     transform: gera path a partir       |
              |       dos fields do evento              |
              |     sink: file, path templado            |
              |                           |
              |   /mnt/logs/{app}/{data}/{instancia}/{app}.log (arquivo atual) |
              |                           |
              |   [rotator] (hora em hora)                |
              |     copytruncate {app}.log -> {app}-{hora}.log.gz |
              ============================
                          |
                          v
                 tail -f / multitail
                 (acompanhamento em tempo real, sempre em {app}.log)
```

## Por que Vector em vez de Logstash

- **Mais leve**: binário único em Rust, sem JVM, footprint de memória muito menor — importante numa EC2 dedicada que só faz esse trabalho.
- **Compatível com Filebeat**: Vector tem source nativa para o protocolo do Beats (`source: "logstash"` recebe eventos no formato lumberjack usado pelo Filebeat/Logstash), então não é necessário trocar o agente na origem.
- **Sink de arquivo com templating dinâmico**: o sink `file` do Vector aceita o `path` como template usando campos do evento (ex: `/mnt/logs/{{ app }}/%Y-%m-%d/{{ instance }}/{{ app }}.log`), o que resolve automaticamente a criação de pastas por app/dia/instância sem nenhuma configuração adicional por aplicação.
- Configuração declarativa em TOML/YAML, mais simples de ler e versionar que pipelines Logstash (Ruby/grok).

## Lado da aplicação (origem — EC2 ou Nomad)

Cada instância/container roda um **Filebeat** apontando para o arquivo de log local da aplicação. A única configuração específica por aplicação fica nos `fields` do Filebeat:

```yaml
filebeat.inputs:
  - type: log
    paths:
      - /var/log/customers-app/*.log
    fields:
      app: customers-app
      instance: ${INSTANCE_ID}    # hostname, EC2 instance-id, ou Nomad alloc ID
    fields_under_root: false

output.logstash:
  hosts: ["concentrador.interno:5044"]
```

- `instance` pode ser resolvido via variável de ambiente (`INSTANCE_ID`, `NOMAD_ALLOC_ID`, hostname) já disponível no ambiente de execução, sem hardcode.
- **Para adicionar uma nova app**: só é preciso instalar/configurar o Filebeat na origem com o `app` correto. O servidor (Vector) não precisa de nenhuma alteração — ele só lê os fields do evento recebido, satisfazendo o requisito 3.

## Lado da concentradora (EC2 dedicada)

- **Vector** roda como serviço (systemd), com: - **Source**: `logstash` (escuta na porta usada pelo Filebeat, ex. 5044). - **Sink**: `file`, com `path` templado a partir de `fields.app`, `fields.instance` e a data, sempre escrevendo no mesmo arquivo "atual":
    ```
    /mnt/logs/{app}/{YYYY-MM-DD}/{instancia}/{app}.log
    ```
- **Disco**: volume EBS dedicado montado em `/mnt/logs`, dimensionado com folga sobre a estimativa de volume diário (a definir quando houver dados reais de volume).
- **Rotação horária** (requisito 5): job separado (cron/systemd timer, hora em hora) faz *copytruncate* do `{app}.log` corrente — copia para `{app}-{HH}.log`, trunca o original no lugar (o Vector continua escrevendo no mesmo arquivo sem interrupção, pois escreve em modo append) — e compacta a cópia para `{app}-{HH}.log.gz`. Implementado só na automação Ansible real (role `logrotate`, ver `ansible/README.md`) — o ambiente Docker local é só para visualizar logs e dashboards, sem rotação.
- **Retenção/arquivamento** (requisito 6): job separado (cron/systemd timer, diário) move os `.gz` de pastas de data com mais de 30 dias para `/mnt/logs/archive/{app}/{YYYY-MM-DD}/{instancia}/`, mantendo a mesma estrutura — mantém a pasta principal só com os logs mais recentes. Implementado só na automação Ansible real (role `archive_logs`, ver `ansible/README.md`) — mesma razão acima, fora do ambiente Docker local.
- **Tuning para alta carga** (muitas fontes enviando log ao mesmo tempo): sysctl de rede/memória/disco (backlog de conexão TCP, buffers de socket, swappiness, dirty ratio) e, no próprio Vector, `LimitNOFILE` elevado (relevante porque um arquivo fica aberto por combinação ativa de app/dia/instância, ver § Métricas abaixo) e buffer em disco no sink `file` para absorver picos de escrita sem aplicar backpressure imediata nas fontes. Implementado só na automação Ansible real (role `os_tuning`, ver `ansible/README.md`) — o ambiente Docker local não precisa lidar com essa escala.

## Tempo real

Como os logs já ficam em arquivos organizados em disco na concentradora, o acompanhamento em tempo real é feito diretamente via:

```
tail -f /mnt/logs/customers-app/2026-08-11/i-0abc123/customers-app.log
```

ou `multitail` para acompanhar várias aplicações/instâncias ao mesmo tempo, sem necessidade de infraestrutura adicional de indexação (Elasticsearch, Loki, etc.) nesta primeira versão.

## Segurança

- Tráfego Filebeat → Vector sem TLS nesta primeira versão, assumindo rede privada (VPC) entre as instâncias/containers e a concentradora.
- Ponto de evolução futuro, se a rede deixar de ser considerada confiável: habilitar TLS mútuo no source `logstash` do Vector e no output do Filebeat.

## Métricas

Objetivo: visualizar no Grafana (já existente, junto com o Prometheus que o alimenta) a saúde da máquina concentradora — quais apps estão enviando logs, quanto espaço cada uma ocupa, uso de disco total e sinais de que o concentrador pode estar em risco.

### node_exporter

Instalado como serviço (systemd) na EC2 concentradora, expondo métricas padrão em `:9100/metrics` para o Prometheus já existente fazer scrape (novo job/target apontando para essa instância). Escopo inicial: **somente a concentradora**, não as instâncias de origem.

Métricas padrão do node_exporter já cobrem boa parte do pedido:

| Necessidade | Métrica(s) |
|---|---|
| Disco total usado vs disponível | `node_filesystem_size_bytes` / `node_filesystem_avail_bytes` (filtrado pelo mountpoint de `/mnt/logs`) |
| Load | `node_load1`, `node_load5`, `node_load15` |
| CPU | `node_cpu_seconds_total` |
| Memória | `node_memory_MemAvailable_bytes` / `node_memory_MemTotal_bytes` |

Além do óbvio, dois riscos específicos **deste** concentrador (muitos arquivos pequenos sendo criados o tempo todo) valem métricas dedicadas:

- **Inodes**: a estrutura `app/dia/instância/hora` cria muitos diretórios e arquivos — é possível esgotar inodes antes de esgotar espaço em disco. Monitorar `node_filesystem_files` / `node_filesystem_files_free` no mesmo mountpoint.
- **File descriptors abertos**: o Vector mantém um arquivo aberto por combinação ativa de app/instância/hora simultaneamente. Se o número de apps/instâncias crescer muito, pode esbarrar em limites do processo. Monitorar `node_filefd_allocated` / `node_filefd_maximum`.
- **I/O de disco**: `node_disk_io_time_seconds_total` (taxa) ajuda a ver se o disco está saturado por escrita de logs, o que impactaria a ingestão.

### Tamanho por aplicação e lista de apps (métrica custom)

`node_exporter` não sabe nada sobre `/mnt/logs/{app}/...` — isso não é uma métrica nativa. Solução: **textfile collector**.

- `node_exporter` roda com `--collector.textfile.directory=/var/lib/node_exporter/textfile_collector`.
- Um script (`log-metrics.sh`), disparado por um **systemd timer** a cada **15 minutos** (intervalo configurável no timer), para cada diretório em `/mnt/logs/{app}`: - calcula o tamanho total com `du -sb`; - pega o timestamp do arquivo mais recente dentro da árvore da app (indica se ela está realmente enviando logs ou parou). - escreve as métricas em um arquivo temporário e faz `mv` atômico para `.prom` (evita o node_exporter ler um arquivo pela metade).

  ```
  # HELP log_app_disk_bytes Espaço em disco ocupado pela aplicação em /mnt/logs
  # TYPE log_app_disk_bytes gauge
  log_app_disk_bytes{app="customers-app"} 5327193600
  log_app_disk_bytes{app="frontend-app"} 1882401920

  # HELP log_app_last_write_timestamp_seconds Timestamp do último log recebido da aplicação
  # TYPE log_app_last_write_timestamp_seconds gauge
  log_app_last_write_timestamp_seconds{app="customers-app"} 1755000123
  log_app_last_write_timestamp_seconds{app="frontend-app"} 1754999870
  ```

- A **lista de aplicações enviando logs** (pedida no requisito) é derivada diretamente do label `app` dessas métricas — não precisa de painel separado: um painel de tabela com `log_app_disk_bytes` já mostra nome da pasta + tamanho ocupado, ordenável por maior consumidor.
- `du -sb` recursivo tem custo de I/O; por isso o intervalo padrão de 15 min (e não 1 min), evitando concorrência com a escrita de logs pelo Vector. O intervalo fica como parâmetro do timer, ajustável sem mudar o script.

### Dashboards no Grafana

- **Tabela — apps enviando logs**: `log_app_disk_bytes` ordenado decrescente, com coluna adicional calculada a partir de `log_app_last_write_timestamp_seconds` (há quanto tempo desde o último log) para identificar apps que pararam de enviar.
- **Disco usado vs disponível**: em vez de gráfico de pizza — que é difícil de ler com precisão em proporções como essa — recomendo um **painel de gauge (percentual usado)** com thresholds de cor (verde/amarelo/vermelho), usando `1 - (node_filesystem_avail_bytes / node_filesystem_size_bytes)` no mountpoint de `/mnt/logs`. Mesma métrica alimenta o alerta de disco cheio, então gauge e alerta ficam coerentes. Pizza continua como opção se a preferência visual for essa.
- **Load / CPU**: série temporal de `node_load1/5/15` normalizada pelo número de cores (`count(node_cpu_seconds_total{mode="idle"}) by (instance)`), para saber se o load é realmente alto relativo à capacidade da máquina.
- **Saúde geral do concentrador**: painéis de memória disponível, inodes livres (%), file descriptors abertos vs limite, e taxa de I/O de disco — os sinais mais prováveis de impactar a ingestão de logs antes que faltar espaço em disco vire o problema principal.

### Alertas (Grafana Alerting)

Como pedido, além dos dashboards:

- **Disco `/mnt/logs`**: warning em 85% usado, crítico em 95%.
- **Inodes `/mnt/logs`**: warning em 85% usado.
- **Load**: alerta se `node_load1` ultrapassar ~1.5x o número de cores por mais de alguns minutos (evita alertar em picos curtos).
- **File descriptors**: warning se uso ultrapassar 80% do limite do processo do Vector.
- **Coleta de métricas de app travada**: o próprio node_exporter expõe `node_textfile_mtime_seconds` para cada arquivo `.prom` — alertar se esse timestamp ficar mais velho que ~2x o intervalo do timer (15 min → alerta se > 30 min), sinal de que o script `log-metrics.sh` parou de rodar.
- Fora de escopo por ora (fica como evolução futura): alerta de app individual crescendo com taxa anormal — precisaria de baseline por app, mais complexo que os limiares fixos acima.

## Pontos em aberto / evoluções futuras

- Volume real de logs por dia (para dimensionar EBS e revisar retenção).
- Se algum dia for necessário busca/indexação (não apenas tail), avaliar acoplar Loki ou Elasticsearch lendo os mesmos arquivos, sem mudar o pipeline de ingestão.
- Nomad: confirmar mecanismo exato para obter um identificador estável de instância (alloc ID muda a cada deploy/restart — pode ser preferível usar o nome do job + task group como parte do path, e o alloc ID apenas como detalhe dentro do arquivo).
