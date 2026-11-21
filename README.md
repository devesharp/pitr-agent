# pitr-agent

Backup **point-in-time** para MariaDB: permite restaurar um banco até um segundo exato, por exemplo um segundo antes de um `DELETE` errado, com tudo guardado num bucket S3 compatível (testado com Cloudflare R2).

- **Uma vez por dia:** faz o dump completo do banco, gravando a posição do binlog, e envia para o bucket.
- **A cada 5 minutos:** fecha o binlog atual e envia os arquivos fechados. A perda máxima num desastre é de cerca de 5 minutos.
- **Em caso de falha:** avisa no Telegram e, se configurado, para de dar sinal no healthchecks.io.
- **Restore:** o `pitr-restore.sh` baixa o dump e os binlogs e restaura até o horário informado, com prévia e confirmação antes de aplicar.

No bucket, os arquivos ficam assim:

```
pitr/<NAME>/full/full_AAAA-MM-DD_HHMMSS.sql.gz   # dumps diários (horário em UTC)
pitr/<NAME>/binlog/mysql-bin.000123              # binlogs
```

## Requisitos

- MariaDB 10.5 ou mais novo. A imagem usa o cliente do MariaDB 12, que funciona com servidores mais antigos. Para um servidor mais novo que o 12, mude o `MARIADB_VERSION` no `Dockerfile`.
- O agente precisa rodar na mesma rede Docker do banco. No Coolify, isso significa estar no mesmo servidor do banco.
- Um bucket S3 compatível e uma credencial com leitura e escrita nele.

## Passo a passo (Coolify)

### 1. Ligar o binlog no banco

No banco: **Configuration → Custom MariaDB Configuration**:

```ini
[mysqld]
log_bin = mysql-bin
binlog_format = ROW
binlog_expire_logs_seconds = 604800
server_id = 1
```

Salve e reinicie o banco, de preferência de madrugada. Para conferir, no Terminal do banco:

```bash
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
mariadb -u root -e "SHOW VARIABLES LIKE 'log_bin'; SHOW BINARY LOGS;"
```

### 2. Criar o usuário do agente

Ele só lê os dados; não consegue alterar nem apagar nada.

```bash
mariadb -u root -e "
CREATE USER 'pitr'@'%' IDENTIFIED BY 'SENHA_FORTE';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD,
      REPLICATION SLAVE, BINLOG MONITOR ON *.* TO 'pitr'@'%';"
```

Se aparecer erro de permissão no `FLUSH BINARY LOGS`, acrescente `BINLOG ADMIN` ao GRANT.

### 3. Criar a aplicação

**+ New → Application →** este repositório → build pack **Dockerfile** → o **mesmo servidor do banco**. Não configure domínio nem portas.

### 4. Variáveis de ambiente

Copie o [`.env.example`](.env.example), preencha os valores e cole em **Environment Variables → Developer view**. Marque `DB_PASSWORD`, `R2_SECRET_ACCESS_KEY` e `TG_TOKEN` como secretas.

| Variável | Descrição |
|---|---|
| `NAME` | Identificador do banco; vira a pasta `pitr/<NAME>/` no bucket |
| `DB_HOST` | Hostname interno do banco (no Coolify, o UUID da URL interna) |
| `DB_USER` / `DB_PASSWORD` | Usuário `pitr` e a senha dele |
| `DATABASES` | Bancos para o dump, separados por espaço |
| `R2_ENDPOINT` | Endpoint S3, **sem** o nome do bucket |
| `R2_BUCKET` | Nome do bucket |
| `R2_ACCESS_KEY_ID` | Access Key (32 caracteres no R2) |
| `R2_SECRET_ACCESS_KEY` | Secret (64 caracteres no R2) |
| `TG_TOKEN` / `TG_CHAT_ID` / `TG_THREAD_ID` | Alertas no Telegram (opcional) |
| `INTERVAL` | Segundos entre envios de binlog (padrão `300`) |
| `DUMP_HOUR` | Hora **UTC** do dump diário (padrão `6`, ou seja, 03h em Brasília) |
| `HC_URL` | URL de ping do healthchecks.io (opcional, recomendado) |

### 5. Deploy e conferência

Nos logs, o esperado é:

```
iniciando PITR para <NAME> (bancos: ...)
dump completo -> full_...sql.gz
dump enviado
binlog enviado: mysql-bin.000001
```

Se aparecer `Credential access key has length 64, should be 32`, a Access Key e o Secret estão trocados.

## Restore

Restaure **sempre num banco novo e vazio**, nunca por cima do banco de produção. O script se recusa a restaurar no `DB_HOST` sem `FORCE=1`.

1. Crie um MariaDB novo, da mesma versão ou mais novo.
2. Descubra o horário exato do problema. O jeito mais seguro é rodar `SELECT UTC_TIMESTAMP();` no banco e usar o horário em UTC.
3. No Terminal da aplicação `pitr-agent`:

```bash
# horário em UTC (recomendado)
TARGET_HOST=<uuid-do-banco-novo> TARGET_PASSWORD='<senha-root>' \
  pitr-restore.sh "2026-11-21 03:54:50" UTC

# ou horário de Brasília
TARGET_HOST=<uuid-do-banco-novo> TARGET_PASSWORD='<senha-root>' \
  pitr-restore.sh "2026-11-21 00:54:50"
```

4. Leia a prévia antes de digitar `sim`:
   - Ela não pode conter a operação que causou o problema (o `DELETE` errado, por exemplo).
   - Se aparecer o aviso de que o horário alvo é **depois do último evento**, o fuso provavelmente está errado. Cancele e confira.
5. O script restaura apenas os eventos **anteriores** ao segundo informado. Dê um ou dois segundos de folga depois da última operação boa.
6. Confira os dados e aponte a aplicação para o banco novo, ou copie de volta o que precisar.

Os binlogs do arquivo que ainda está aberto (os últimos 5 minutos, no máximo) não estão no bucket. Se o servidor original ainda estiver de pé, eles continuam em `/var/lib/mysql` no container do banco.

## Custos e retenção (R2)

- Crie uma regra de ciclo de vida para o prefixo `pitr/` apagando após **35 dias**. Assim você consegue voltar a qualquer minuto dos últimos 30 dias.
- Com Bucket Lock, cada arquivo fica no mínimo pelo período do lock. Evite backups completos de hora em hora em paralelo: o agente já cobre isso.
- Um banco de 650 MB custa menos de US$ 1 por mês no R2.

## Desenvolvimento

```bash
docker build -t pitr-agent .
docker run --rm --env-file .env pitr-agent
```

Nunca faça commit do `.env`.
