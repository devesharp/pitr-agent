# Use a mesma versão principal do MariaDB do servidor, ou mais nova (o cliente antigo não reconhece servidor novo)
ARG MARIADB_VERSION=12
FROM mariadb:${MARIADB_VERSION}
COPY --from=rclone/rclone:latest /usr/local/bin/rclone /usr/local/bin/rclone
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /root/.config/rclone && touch /root/.config/rclone/rclone.conf
COPY pitr-agent.sh pitr-restore.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/pitr-agent.sh /usr/local/bin/pitr-restore.sh
ENTRYPOINT ["/usr/local/bin/pitr-agent.sh"]
