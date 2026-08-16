# "EC2 local": Amazon Linux 2023 de verdade rodando systemd como init +
# sshd, só pra testar a automação Ansible (ansible/vector-provision.yml)
# contra um SO real, sem precisar de uma conta AWS. Não é uma emulação da
# API da AWS (isso é o que o LocalStack faz, e a versão free dele não
# executa instâncias EC2 de verdade — ver docker/local-ec2/README.md) — é
# literalmente Amazon Linux 2023 rodando em container.
FROM amazonlinux:2023

RUN dnf -y install \
      systemd \
      openssh-server \
      sudo \
      python3 \
      shadow-utils \
      tar \
      gzip \
    && dnf clean all

# Usuário "ec2-user" com sudo sem senha, igual à AMI oficial da AWS —
# é o usuário que o inventário local (inventory/local-ec2.ini) usa.
RUN useradd -m -s /bin/bash ec2-user \
    && echo "ec2-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ec2-user \
    && chmod 440 /etc/sudoers.d/ec2-user \
    && mkdir -p /home/ec2-user/.ssh \
    && chmod 700 /home/ec2-user/.ssh \
    && chown -R ec2-user:ec2-user /home/ec2-user/.ssh

# Chave pública gerada por generate-ssh-key.sh (não versionada — ver
# .gitignore). O build falha com uma mensagem clara se você esquecer de
# rodar o script antes.
COPY ssh/id_ed25519.pub /home/ec2-user/.ssh/authorized_keys
RUN chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys \
    && chmod 600 /home/ec2-user/.ssh/authorized_keys \
    && ssh-keygen -A \
    && systemctl enable sshd

# PAM mínimo (ver pam-sshd) — evita o pam_unix/unix_chkpwd padrão, que em
# hosts Ubuntu esbarra num perfil AppArmor do host vinculado ao path do
# binário (ver comentário no arquivo). Aplica pro sshd e pro sudo (o
# `become: true` do Ansible passa pelo mesmo unix_chkpwd via sudo).
COPY pam-sshd /etc/pam.d/sshd
COPY pam-sshd /etc/pam.d/sudo

EXPOSE 22
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
