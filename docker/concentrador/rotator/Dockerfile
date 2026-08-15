FROM alpine:3.20

RUN apk add --no-cache bash coreutils gzip

COPY rotate-logs.sh /usr/local/bin/rotate-logs.sh
COPY crontab /etc/crontabs/root
RUN chmod +x /usr/local/bin/rotate-logs.sh \
    && touch /var/log/rotate-logs.log

CMD ["crond", "-f", "-l", "2"]
