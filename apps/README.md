# Apps de exemplo (host) — geradoras de log

3 apps de teste rodando **direto no host** (sem Docker), cada uma
enviando log via Filebeat para o Vector local de
[`docker/concentrador`](../docker/concentrador/README.md). Cada app é
uma NestJS mínima (`NestFactory.createApplicationContext`, sem servidor
HTTP) que só fica escrevendo linhas de log genéricas em arquivo.

Cada app é a sua própria pasta autocontida (`app1/`, `app2/`, `app3/`),
sem imagem/compose compartilhado — o nome da app é fixado no código
(`APP_NAME` em `src/log-generator.service.ts`).

## Estrutura

```
apps/
├── app1/               # NestJS mínima, escreve apps/app1/logs/app1.log
├── app2/               # idêntica, escreve apps/app2/logs/app2.log
├── app3/               # idêntica, escreve apps/app3/logs/app3.log
└── filebeat/
    └── filebeat.yml    # cópia versionada do arquivo usado pelo Filebeat do host
```

`app1`, `app2` e `app3` são idênticas exceto pela constante `APP_NAME` em
`src/log-generator.service.ts` (e o `name` no `package.json`) — o log cai
sempre em `apps/<nome>/logs/<nome>.log`, resolvido relativo ao próprio
código (`__dirname`), então funciona não importa de onde você rode
`npm start`.

## Pré-requisito: Node.js

Este host **não tem Node.js instalado** (verificado: `node`/`npm` não
encontrados). Instale Node 20+ antes de seguir — ex. via
[nvm](https://github.com/nvm-sh/nvm) ou o pacote da sua distro. Sem isso os
passos abaixo (`npm install`/`npm run build`/`npm start`) não funcionam.

## 1. Rodar as 3 apps

Em 3 terminais (ou em background com `nohup ... &`), uma por pasta:

```bash
cd apps/app1 && npm install && npm run build && npm start
cd apps/app2 && npm install && npm run build && npm start
cd apps/app3 && npm install && npm run build && npm start
```

Ou tudo em background num terminal só:

```bash
for app in app1 app2 app3; do
  ( cd apps/$app && npm install && npm run build && nohup npm start > /tmp/$app.log 2>&1 & )
done
```

Cada app cria `apps/<nome>/logs/<nome>.log` e escreve uma linha a cada
1-3s. Confira com `tail -f apps/app1/logs/app1.log`.

## 2. Apontar o Filebeat do host para o Vector local

O [`docker/concentrador`](../docker/concentrador/README.md) precisa estar
de pé (`cd docker/concentrador && mkdir -p data/logs data/textfile &&
UID=$(id -u) GID=$(id -g) docker compose up -d`, se ainda não estiver) e
alcançável em `localhost:5044` (porta publicada pelo compose).
`apps/filebeat/filebeat.yml` já aponta pra lá.

O arquivo que o Filebeat de fato lê é
`/home/fabio/filebeat-9.5.1-linux-x86_64/filebeat.yml` — **fora deste
repo** (path do host). `apps/filebeat/filebeat.yml` é a cópia versionada;
sempre que editar um, replique no outro. Para instalar a versão deste repo:

```bash
cp apps/filebeat/filebeat.yml /home/fabio/filebeat-9.5.1-linux-x86_64/filebeat.yml
```

(já copiado e validado com `./filebeat test config -c filebeat.yml` → `Config
OK` — mas repita esse `cp` sempre que editar `apps/filebeat/filebeat.yml`
de novo).

E rodar (não executei isso por você — só as instruções, como pedido):

```bash
cd /home/fabio/filebeat-9.5.1-linux-x86_64
./filebeat -e -c filebeat.yml
```

`-e` manda o log do próprio Filebeat para stderr (fica visível no
terminal, útil para ver os 3 inputs conectando e os eventos sendo
enviados). `Ctrl+C` para parar.

Não precisa exportar `HOSTNAME` nem nenhum field `instance`: o libbeat
(motor do Filebeat) já inclui um `host.name` (hostname da máquina) em todo
evento, por padrão, independente de config — é isso que o Vector usa para
organizar os logs por instância.

Se o Filebeat recusar subir por causa de permissão do arquivo de config
(`config file ... needs to be owned by ...`), rode com
`--strict.perms=false` — não deveria ser necessário aqui já que o arquivo
pertence ao seu próprio usuário, mas fica registrado caso apareça.

## 3. Ver os logs chegando no concentrador

```bash
tail -f docker/concentrador/data/logs/*/*/*/*.log
```

Em poucos segundos devem aparecer as 3 apps
(`docker/concentrador/data/logs/app1/<data>/<hostname>/app1.log` etc. —
`<hostname>` é o `host.name` que o libbeat inclui sozinho em todo evento).

As mesmas 3 apps também aparecem no dashboard do Grafana
(`http://localhost:3001`, sem login) — tabela "Aplicações enviando logs"
com tamanho em disco e há quanto tempo cada uma mandou log pela última
vez. Essa tabela só atualiza a cada varredura do `textfile-collector`
(15 min por padrão), então pode demorar para as apps aparecerem lá mesmo
já enviando log normalmente — ver
[`docker/concentrador/README.md`](../docker/concentrador/README.md).

## Adicionando uma 4ª app

1. Copie uma pasta existente: `cp -r apps/app3 apps/app4`.
2. Em `apps/app4/src/log-generator.service.ts`, troque
   `const APP_NAME = 'app3';` → `const APP_NAME = 'app4';`.
3. Em `apps/app4/package.json`, troque `"name": "app3-log-generator"` →
   `"name": "app4-log-generator"` (cosmético, não afeta nada).
4. Em **`apps/filebeat/filebeat.yml`** (e depois na cópia real em
   `/home/fabio/filebeat-9.5.1-linux-x86_64/filebeat.yml`), adicione mais
   um bloco em `filebeat.inputs`:

   ```yaml
     - type: filestream
       id: app4
       paths:
         - /home/fabio/projects/vector-stack/apps/app4/logs/app4.log
       fields:
         app: app4
       fields_under_root: false
   ```

   `id` precisa ser único entre os inputs (não repita um `id` já usado por
   outra app) — é a chave que o Filebeat usa pra rastrear até onde já leu
   cada arquivo.

5. `cd apps/app4 && npm install && npm run build && npm start`.
6. Reinicie o Filebeat (`Ctrl+C` e rode de novo) para pegar o novo input —
   Filebeat só lê `filebeat.inputs` na inicialização.

Nenhuma mudança do lado do Vector é necessária — ele só lê os `fields`
que chegam no evento.
