# Guia Rápido - Sincronizador MySQL → SQLite

## 🚀 Instalação em 3 Passos

```bash
# 1. Dar permissão de execução
chmod +x setup-sync.sh

# 2. Executar instalação
sudo ./setup-sync.sh

# 3. Pronto! A sincronização está configurada
```

## 📝 Comandos Principais

```bash
# Sincronizar manualmente
sync-mail-db

# Verificar status
check-mail-sync

# Ver logs em tempo real
tail -f /var/log/mysql-sqlite-sync.log
```

## ⚙️ Gerenciar Sincronização (Systemd)

```bash
# Ver status
systemctl status mysql-sqlite-sync.timer

# Parar
systemctl stop mysql-sqlite-sync.timer

# Iniciar
systemctl start mysql-sqlite-sync.timer

# Ver logs
journalctl -u mysql-sqlite-sync.service -f
```

## 🔧 Configuração Manual

Editar `/etc/postfix/db/sync-config.json`:

```json
{
  "mysql": {
    "host": "localhost",
    "user": "root",
    "password": "sua_senha",
    "database": "mailserver"
  },
  "sqlite": {
    "path": "/etc/postfix/db/mailserver.db"
  }
}
```

## 📊 Verificar Dados

```bash
# MySQL
mysql -u root -p mailserver -e "SELECT COUNT(*) FROM tb_mail_mailbox"

# SQLite
sqlite3 /etc/postfix/db/mailserver.db "SELECT COUNT(*) FROM tb_mail_mailbox"

# Comparar ambos
check-mail-sync
```

## 🐛 Problemas Comuns

**Erro de conexão MySQL:**

```bash
# Testar conexão
mysql -h localhost -u root -p mailserver
```

**Sincronização não está rodando:**

```bash
# Verificar cron/timer
systemctl list-timers | grep mysql-sqlite
# ou
crontab -l | grep mysql-sqlite
```

**Permissões:**

```bash
chmod 600 /etc/postfix/db/sync-config.json
chmod 640 /etc/postfix/db/mailserver.db
chown postfix:postfix /etc/postfix/db/mailserver.db
```

## 📈 O Que o Script Faz

1. ✅ Busca dados do MySQL
2. ✅ Compara com SQLite (usando hash MD5)
3. ✅ Insere novos registros
4. ✅ Atualiza registros modificados
5. ✅ Ignora registros inalterados
6. ✅ Loga todas as operações

## 🔄 Intervalo de Sincronização

**Padrão:** 5 minutos

**Alterar (Systemd):**

```bash
sudo systemctl edit mysql-sqlite-sync.timer
```

Adicionar:

```ini
[Timer]
OnUnitActiveSec=10min
```

**Alterar (Cron):**

```bash
crontab -e
```

Editar linha para 10 minutos:

```cron
*/10 * * * * /usr/bin/python3 /usr/local/bin/mysql-to-sqlite-sync.py ...
```

## 📚 Mais Informações

Consulte `SYNC-README.md` para documentação completa.
