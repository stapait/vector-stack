Eu gostaria agora de executar o Ansible localmente (na máquina Host) para testar a automação.

Só que ao invés de testar na AWS, quero que suba uma local stack com EC2.

O Ansible já está instalado na máquina host, está com a instalação padrão sem nenhum pacote. Gostaria que, caso pacotes ou libs sejam necessárias na automação, isso fosse especificado em algum arquivo (como do Galaxy) e instalado automaticamente.

Crie uma outra pasta dentro de docker chamada local-stack, e um docker compose que rode a versão free do Local Stack, que suporta EC2. Crie na local stack uma EC2 com Amazon Linux 2023 e depois rode a automação nesta máquina. Acredito que com essa versão da pra executar toda a automação do Vector.

Isso tudo é possível?