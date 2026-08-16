# VM Vagrant — testar a automação Ansible contra uma VM real

Complementar a [`docker/local-ec2/`](../docker/local-ec2/README.md): mesma
ideia (rodar [`ansible/vector-provision.yml`](../ansible/vector-provision.yml)
contra um Amazon Linux 2023 real, sem precisar de conta AWS), mas numa VM de
verdade (VirtualBox) em vez de container — kernel próprio da imagem (não o
kernel do host), sem nenhum dos truques de `--privileged`/cgroup/PAM que o
container precisou (ver `docker/local-ec2/README.md`) para rodar `systemd`
dentro de um container.

## Por que `bento/amazonlinux-2023`

A AWS não publica uma box oficial de Amazon Linux 2023 para Vagrant/VirtualBox
(só AMIs, para EC2 mesmo). A imagem mais próxima disponível é a
[`bento/amazonlinux-2023`](https://portal.cloud.hashicorp.com/vagrant/discover/bento/amazonlinux-2023),
mantida pelo projeto [Bento](https://github.com/chef/bento) (Chef/Progress),
buildada a partir da AMI oficial da AWS com Packer. Testado aqui: é
literalmente Amazon Linux 2023 — `/etc/os-release` mostra `ID="amzn"`,
`VERSION_ID="2023"`, e o kernel já vem com o sufixo `amzn2023`
(`6.1.155-176.282.amzn2023.x86_64` na versão testada), diferente da imagem
Docker `amazonlinux:2023` (que roda no kernel do host).

Única diferença relevante encontrada: usuário Vagrant padrão é `vagrant` (não
`ec2-user` como na AMI oficial da AWS/como o container `local-ec2` simula) —
não é uma incompatibilidade da automação, só uma convenção diferente de quem
built a box; refletido no inventário (`ansible_user=vagrant`).

## O que tem aqui

- **`Vagrantfile`**: define a VM (`bento/amazonlinux-2023`, 1 vCPU, 1GB RAM,
  hostname `vector-concentrador`, rede privada com IP fixo `192.168.56.20`
  para o inventário do Ansible não depender de IP dinâmico).
- **Disco extra de 3GB** (`config.vm.disk`), simulando o volume EBS que numa
  EC2 real já chega montado em `/mnt/vector` antes do Ansible rodar (a
  automação não mexe em volume — ver `AWS.md`, seção 3). Mais fiel que o
  volume Docker nomeado usado no `local-ec2`: aqui é um disco de verdade,
  formatado `ext4` e registrado em `/etc/fstab` dentro da VM.
- **`provision/mount-vector-volume.sh`**: shell provisioner que formata (só
  na primeira vez) e monta esse disco em `/mnt/vector` — parte do
  "provisionamento de infraestrutura" que fica fora do Ansible, exatamente
  como aconteceria numa EC2 real.
- **`test.sh`**: sobe a VM e roda `vector-provision.yml` contra ela, no mesmo
  espírito do `docker/local-ec2/test.sh`.
- **`../ansible/inventory/vagrant.ini`**: inventário apontando pro IP fixo,
  usando a chave privada que o próprio `vagrant up` gera
  (`.vagrant/machines/vector/virtualbox/private_key` — regenerada a cada
  `vagrant destroy` + `vagrant up`, por isso `StrictHostKeyChecking=no`,
  aceitável aqui pelo mesmo motivo do `local-ec2`: descartável/local).

## Como usar

Pré-requisitos: Vagrant + VirtualBox instalados no host (nada além disso —
sem plugins).

```bash
cd vagrant
./test.sh
```

Isso: baixa a box `bento/amazonlinux-2023` (só na primeira vez, ~500MB),
sobe a VM, formata e monta o disco extra em `/mnt/vector`, e roda
`vector-provision.yml` de verdade contra a VM usando
`../ansible/inventory/vagrant.ini`.

Pra investigar o resultado:

```bash
vagrant ssh
sudo systemctl status vector node_exporter vector-metrics.timer vector-logrotate.timer vector-archive.timer
sudo journalctl -u vector -n 50
ls -la /mnt/vector/logs
```

Rodar de novo (`./test.sh`) é seguro — a automação é idempotente, só muda o
que precisar.

Pra destruir a VM (equivalente a "resetar a EC2 e o EBS"):

```bash
./test.sh --down
```

## Validado de ponta a ponta

Rodado de verdade (não só revisado), contra a VM real (não o container
`local-ec2`):

- `vector-provision.yml` completo, sem falhas, **sem nenhuma incompatibilidade
  encontrada** — todos os bugs de compatibilidade com Amazon Linux 2023 já
  tinham sido pegos e corrigidos rodando contra o `docker/local-ec2` (ex.
  `findutils`, ver `AWS.md`), então nada de provisionamento à parte foi
  necessário aqui.
- Idempotência confirmada: segunda execução do playbook, `changed=0` em
  todas as tasks.
- Evento de teste enviado pelo protocolo Beats
  (`docker/concentrador/scripts/send-test-log.py`) direto pro Vector da VM
  (`192.168.56.20:5044`) — apareceu em
  `/mnt/vector/logs/<app>/<data>/<instancia>/<app>.log`, dono `vector:vector`.
- Rotação (`vector-logrotate.service`) testada manualmente — gerou
  `<app>-<HH>.log.gz` corretamente.
- Métricas: `node_exporter` (`:9100/metrics`) expondo `log_app_disk_bytes` e
  `log_app_last_write_timestamp_seconds` depois de rodar
  `vector-metrics.service` manualmente.

## Limitações conhecidas

- Sem Security Group / rede real da AWS — só valida que a automação de
  provisionamento roda corretamente num Amazon Linux 2023 real, não a
  topologia de rede da VPC.
- IP privado fixo (`192.168.56.20`) é só de rede host-only do VirtualBox —
  não representa o IP real que a EC2 vai ter.

## Próximo passo

Ambiente pronto para, na sequência, rodar aplicações NestJS no host
(máquina física) enviando logs para o Vector desta VM via rede — item
seguinte do `next.md`, ainda não feito aqui.
