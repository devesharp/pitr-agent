FROM mariadb:11
COPY --from=rclone/rclone:latest /usr/local/bin/rclone /usr/local/bin/rclone
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY pitr-agent.sh /usr/local/bin/pitr-agent.sh
RUN chmod +x /usr/local/bin/pitr-agent.sh
ENTRYPOINT ["/usr/local/bin/pitr-agent.sh"]
