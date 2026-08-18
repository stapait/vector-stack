FROM alpine:3.20

RUN apk add --no-cache bash coreutils findutils

COPY log-metrics.sh /usr/local/bin/log-metrics.sh
RUN chmod +x /usr/local/bin/log-metrics.sh

ENTRYPOINT ["/bin/sh", "-c"]
CMD ["while true; do /usr/local/bin/log-metrics.sh; sleep \"${INTERVAL_SECONDS:-900}\"; done"]
