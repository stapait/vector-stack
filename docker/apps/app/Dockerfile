FROM node:20-slim

# Filebeat (repositório oficial Elastic) roda no mesmo container que a app,
# lendo o arquivo de log local e enviando para o Vector da concentradora.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl gnupg ca-certificates \
    && curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" > /etc/apt/sources.list.d/elastic-8.x.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends filebeat \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json tsconfig.json ./
RUN npm install
COPY src ./src
RUN npm run build

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /var/log/app

ENTRYPOINT ["/entrypoint.sh"]
