# EC2 local — testar a automação Ansible sem AWS

Container com **Amazon Linux 2023 de verdade**, rodando `systemd` como
processo 1 e `sshd` ativo, só para testar
[`ansible/vector-provision.yml`](../../ansible/vector-provision.yml) contra
um SO real — sem precisar de uma conta AWS nem de uma EC2 de verdade.

## Por que não LocalStack

A ideia original era usar o [LocalStack](https://www.localstack.cloud/)
(free/Community) para simular a EC2. Não dá: o suporte a EC2 do LocalStack
Community é praticamente só o *control plane* mockado (`RunInstances`,
`DescribeInstances` etc. respondem e guardam metadados), mas **não sobe uma
VM/container com SO de verdade** — não tem SSH, não tem systemd, não tem
filesystem pra instalar nada. Dá pra usar LocalStack pra testar código que
chama a API da AWS (Terraform, boto3, CloudFormation), mas não pra rodar
uma automação Ansible que precisa entrar por SSH e mexer no SO (`dnf`,
`systemd`, montar diretório, etc.) — que é exatamente o que
`vector-provision.yml` faz.

Este container resolve o problema real (testar a automação de ponta a
ponta) de um jeito mais direto: um SO real, sem simular nada da AWS.

## O que tem aqui

- **`systemd` como init** (`CMD ["/usr/sbin/init"]`), não só um container
  de aplicação — precisa rodar `--privileged` com `cgroup: host` (já
  configurado no `docker-compose.yml`). É o "preço de entrada" de ter um
  init de verdade gerenciando serviços dentro de um container.
- **`sshd`** habilitado, usuário `ec2-user` com sudo sem senha (igual à AMI
  oficial da AWS), autenticação só por chave SSH.
- **Volume nomeado montado em `/mnt/vector`**, simulando o EBS que a role
  `common` espera encontrar já montado — aparece em `/proc/mounts` como
  ponto de montagem de verdade, então o `assert` da automação passa sem
  precisar de nenhum tratamento especial.
- **`pam-sshd`**: substitui o `/etc/pam.d/sshd`/`sudo` padrão do AL2023.
  Necessário porque o `pam_unix` padrão aciona o helper setuid
  `unix_chkpwd` pra ler `/etc/shadow`, e em hosts Ubuntu isso esbarra num
  perfil AppArmor do **host** vinculado ao path do binário (carregado no
  kernel do host, não isolado por container — `--security-opt
  apparmor=unconfined` não resolve porque a transição de perfil é por path
  do executável, não por confinamento do processo chamador). Solução: PAM
  mínimo (`pam_permit`) só pra esta caixa de teste descartável — a
  autenticação real continua sendo a chave pública, verificada pelo
  próprio `sshd`, sem passar por isso. Comentário completo no arquivo.

## Como usar

```bash
cd docker/local-ec2
./test.sh
```

Isso: gera uma chave SSH efêmera (`generate-ssh-key.sh`, se ainda não
existir — nunca é versionada), builda e sobe o container, espera o `sshd`
responder, instala as collections do Galaxy declaradas em
[`../../ansible/requirements.yml`](../../ansible/requirements.yml) (hoje
nenhuma — a automação só usa módulos builtin do `ansible-core`, então esse
passo é um no-op, mas fica pronto caso isso mude), e roda
`vector-provision.yml` de verdade contra o container, usando o inventário
[`../../ansible/inventory/local-ec2.ini`](../../ansible/inventory/local-ec2.ini).

Pra investigar o resultado depois:

```bash
ssh -i ssh/id_ed25519 -p 2222 ec2-user@127.0.0.1
sudo systemctl status vector node_exporter vector-metrics.timer vector-logrotate.timer vector-archive.timer
sudo journalctl -u vector -n 50
ls -la /mnt/vector/logs
```

Rodar de novo (`./test.sh`) é seguro — a automação é idempotente, só muda o
que precisar.

Pra derrubar tudo (container + volume, "reseta o EBS"):

```bash
./test.sh --down
```

## Limitações conhecidas desta simulação

- O `assert` de ponto de montagem passa porque um volume Docker aparece em
  `/proc/mounts`, não porque isso simula de verdade um volume EBS anexado
  via AWS API — a role `common` nunca tentou fazer isso mesmo (ver
  `AWS.md`, seção 3, "O que não faz").
- Sem Security Group de verdade — a porta 5044 do Vector não é testada
  aqui contra nenhum cliente; só valida que a automação de provisionamento
  da concentradora roda corretamente num Amazon Linux 2023 real.
- `amazonlinux:2023` (imagem Docker) e a AMI oficial da EC2 não são
  bit-a-bit idênticas (a imagem de container é mais enxuta) — foi
  justamente essa diferença que expôs o bug do `findutils` (ver
  `AWS.md`, seção 3): a AMI oficial provavelmente já vem com ele, a imagem
  de container não. Mesmo assim usam o mesmo `dnf`/`systemd`, então esse
  tipo de lacuna de pacote é exatamente o tipo de coisa que rodar contra
  este container pega antes de chegar numa EC2 de verdade.

## Validado de ponta a ponta

Rodado de verdade (não só revisado): `vector-provision.yml` completo sem
falhas, idempotência confirmada (rodar de novo só reaplica o que mudou), e
um evento de teste enviado pelo protocolo Beats direto pro Vector rodando
no container — apareceu corretamente em
`/mnt/vector/logs/<app>/<data>/<instancia>/<app>.log`, com dono `vector`.
Rotação (`vector-logrotate.service`) e arquivamento
(`vector-archive.service`) também testados manualmente, produzindo
`<app>-<HH>.log.gz` e movendo pra `/mnt/vector/archive/...` como esperado.
