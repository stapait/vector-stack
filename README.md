# vector-stack

Centralização de logs de múltiplas aplicações (EC2 + containers Nomad) numa
única EC2 concentradora, com acompanhamento em tempo real via `tail -f` /
`multitail` e observabilidade no Grafana/Prometheus.

## O que essa arquitetura faz, em alto nível

Cada aplicação (rodando numa EC2 ou num container Nomad) escreve seu log
normalmente num arquivo de texto local. Um **Filebeat** ao lado da
aplicação lê esse arquivo e envia os eventos, com dois campos fixos (`app` e
`instance`), para uma máquina concentradora.

Na concentradora, o **Vector** recebe esses eventos (falando o protocolo do
Filebeat/Logstash) e grava cada linha num arquivo organizado por
app/dia/instância:

```
/mnt/logs/{app}/{YYYY-MM-DD}/{instancia}/{app}.log
```

Esse `{app}.log` é sempre o arquivo "atual" — dá para `tail -f` direto nele
a qualquer momento. Um job de **rotação** fecha esse arquivo a cada hora
(vira `{app}-{HH}.log.gz`) e um job de **arquivamento** move os `.gz` com
mais de 30 dias para uma pasta `/archive`, mantendo a mesma estrutura — a
pasta principal fica sempre só com os logs recentes.

Métricas da concentradora (disco, CPU, memória, inodes, file descriptors, e
quanto espaço cada app está ocupando) são expostas via `node_exporter` +
métricas custom, coletadas pelo Prometheus e visualizadas num dashboard do
Grafana.

O ponto central do design: **adicionar uma aplicação nova não exige nenhuma
mudança do lado da concentradora** — o Vector só lê os campos `app`/
`instance` que chegam no evento. Basta a aplicação nova rodar um Filebeat
apontando pra ela mesma.

Decisões de arquitetura completas, com as alternativas consideradas e o
porquê de cada escolha (Vector vs. Logstash, sem TLS por ora, etc.), estão
em [`arquitetura.md`](./arquitetura.md).

## Por que Vector, e não Logstash

A concentradora recebe eventos no protocolo Beats/Logstash (o mesmo que o
Filebeat já fala) e só precisa fazer uma coisa com cada um: gravar a linha
no arquivo certo, decidido pelos campos `app`/`instance` que vieram no
evento. Isso é pouco processamento, mas roda continuamente numa EC2
dedicada — então o custo de operar a ferramenta que faz isso importa tanto
quanto o que ela faz. Se a escolha tivesse sido Logstash no lugar do
Vector, para o mesmo trabalho:

- **Performance e footprint de recursos**: Vector é um binário único em
  Rust, sem garbage collector, e fica na casa de poucas dezenas de MB de
  RAM em repouso. Logstash roda sobre uma JVM — o `jvm.options` que vem no
  pacote já sobe com heap de 1GB por padrão (`-Xms1g -Xmx1g`), e a própria
  documentação da Elastic recomenda 4-8GB de heap para cenários de
  ingestão típicos em produção — bem acima do que uma pipeline
  "recebe e grava em arquivo" precisaria. Some a isso o tempo de
  start/warm-up da JVM (vários segundos) contra o início praticamente
  instantâneo do Vector. Numa EC2 pequena que também roda `node_exporter` e
  o textfile collector, esse overhead de JVM é recurso que sobra para o
  resto do sistema não ter, sem ganho de throughput proporcional para um
  pipeline tão simples quanto este.
- **Configuração**: o modelo do Vector (source → sink, TOML/YAML
  declarativo) é direto para esse caso de uso. Logstash usa uma DSL própria
  (blocos `input`/`filter`/`output`, sintaxe Ruby-like, tipicamente com
  `grok` para parsear texto livre) — poder que não é necessário aqui, já
  que não há nenhum parsing de mensagem a fazer: o Filebeat já entrega os
  campos prontos, e a concentradora só decide o path do arquivo a partir
  deles. Carregar a maquinaria de filtro do Logstash para um pipeline que
  não filtra nada é complexidade sem retorno.
- **Nova aplicação sem tocar na concentradora**: aqui vale uma correção —
  isso **não é exclusividade do Vector**. O output `file` do Logstash
  também aceita path dinâmico via referência a campo do evento (sintaxe
  `%{[fields][app]}`, equivalente ao `{{ app }}` do sink `file` do Vector),
  então tecnicamente o Logstash também conseguiria gravar
  `/mnt/vector/logs/{app}/...` sem reconfiguração por app nova. A vantagem
  prática do Vector aqui não é capacidade, é superfície operacional: com
  Logstash, manter essa promessa de "zero-touch" em produção significa
  também manter uma JVM saudável (heap, GC pauses, tempo de reload de
  pipeline) e uma pipeline com estágio de filtro que, mesmo vazio, ainda é
  outro ponto de configuração para errar. No Vector, o pipeline inteiro é
  literalmente `source` (recebe Beats) → `sink` (grava com path templado) —
  menos peça girando para essa garantia continuar valendo conforme o
  número de aplicações cresce.

## Estrutura do repositório

```
arquitetura.md              # decisões de design completas
docker/
├── concentrador/           # Vector (porta 5044), local só — sem rotação/métricas
│   └── README.md           # detalhes do serviço, endpoint, como enviar logs
└── apps/                   # apps fictícias que geram log (NestJS + Filebeat)
    └── README.md           # como rodar e como adicionar uma nova app
```

## Como executar e testar com Docker

Tudo roda localmente via Docker Compose, em dois compose files separados —
o do concentrador **precisa subir primeiro**, pois é ele quem cria a rede
Docker (`vector-stack`) usada pelas apps para alcançar o Vector.

### 1. Subir a concentradora

```bash
cd docker/concentrador
UID=$(id -u) GID=$(id -g) docker compose up -d
```

Isso sobe só o Vector, escutando na porta `5044`. Este compose local é
propositalmente mínimo — sem rotação, arquivamento ou métricas/dashboard
(essas peças existem na automação Ansible real, ver [`AWS.md`](./AWS.md)).

O `UID`/`GID` na frente do comando faz o Vector gravar os arquivos em
`data/logs` com o dono/grupo do seu usuário — sem isso ele roda como
`root` dentro do container e você não consegue ler/mover esses arquivos do
host depois. Repita esse prefixo em qualquer `docker compose` rodado nesta
pasta (`up`, `restart` etc.).

### 2. Subir as apps geradoras de log

```bash
cd ../apps
docker compose up -d --build
```

Sobe 3 apps fictícias (`orders-app`, `payments-app`, `shipping-app`), cada
uma escrevendo log local e enviando via Filebeat para o Vector.

### 3. Acompanhar os logs chegando

```bash
cd ../concentrador
tail -f data/logs/*/*/*/*.log
# ou, com multitail instalado:
multitail data/logs/*/*/*/*.log
```

Em poucos segundos deve aparecer log das 3 apps, um arquivo por
app/dia/instância.

### 4. Adicionar uma app nova (validar "zero mudança no servidor")

Veja o passo a passo em [`docker/apps/README.md`](./docker/apps/README.md)
— copiar um bloco de serviço no compose + um arquivo de Filebeat, sem
mexer em nada do lado do Vector.

Alternativa: rodar a app direto no host (fora de container), com o
Filebeat apontando `output.logstash.hosts` para `localhost:5044` — chega
igual em `data/logs`, sem mudar nada do lado do Vector.

### 5. Parar tudo

```bash
cd docker/apps && docker compose down
cd ../concentrador && docker compose down
```

Os logs em `docker/concentrador/data/logs` são bind mount e continuam no
disco mesmo depois do `down -v`.
