#!/usr/bin/env python3
"""
Envia um evento de teste para o Vector usando o protocolo lumberjack (Beats),
o mesmo usado pelo output "logstash" do Filebeat. Serve para validar o
pipeline de ingestao sem precisar rodar um Filebeat de verdade.

Uso:
  python3 send-test-log.py [host] [porta] [app] [instance] [mensagem]

Exemplo:
  python3 send-test-log.py localhost 5044 customers-app i-0abc123 "log de teste"
"""
import json
import socket
import struct
import sys
import time


def send_event(host: str, port: int, event: dict) -> None:
    payload = json.dumps(event).encode("utf-8")

    with socket.create_connection((host, port), timeout=5) as sock:
        # Frame de window size: avisa que vamos mandar 1 evento na sequencia.
        sock.sendall(b"2W" + struct.pack(">I", 1))

        # Frame de dados JSON: versao '2', tipo 'J', seq=1, tamanho, payload.
        sock.sendall(b"2J" + struct.pack(">I", 1) + struct.pack(">I", len(payload)) + payload)

        ack = sock.recv(6)
        if len(ack) == 6 and ack[0:2] == b"2A":
            seq = struct.unpack(">I", ack[2:6])[0]
            print(f"ACK recebido do Vector, seq={seq}")
        else:
            print(f"Resposta inesperada do Vector: {ack!r}")


def main() -> None:
    host = sys.argv[1] if len(sys.argv) > 1 else "localhost"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5044
    app = sys.argv[3] if len(sys.argv) > 3 else "app-teste"
    instance = sys.argv[4] if len(sys.argv) > 4 else "instancia-teste"
    message = sys.argv[5] if len(sys.argv) > 5 else f"log de teste gerado em {time.strftime('%Y-%m-%d %H:%M:%S')}"

    event = {
        "@timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "message": message,
        "fields": {
            "app": app,
            "instance": instance,
        },
    }

    send_event(host, port, event)


if __name__ == "__main__":
    main()
