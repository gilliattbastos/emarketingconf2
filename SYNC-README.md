# Sincronizador MySQL → SQLite

Script Python para sincronização automática de dados entre MySQL e SQLite para servidor de email.

## 📋 Características

- ✅ **Sincronização incremental**: Detecta apenas novos registros e alterações
- ✅ **Detecção de mudanças**: Usa hash MD5 para identificar registros modificados
- ✅ **Três tabelas**: tb_mail_domain, tb_mail_mailbox, tb_mail_alias
- ✅ **Logging completo**: Registra todas as operações
- ✅ **Configuração flexível**: Via arquivo JSON ou argumentos de linha de comando
- ✅ **Agendamento automático**: Configuração via cron
- ✅ **Rollback em caso de erro**: Transações seguras

## 🚀 Instalação Rápida

```bash
# Executar script de instalação
sudo ./setup-sync.sh
```

O script irá:

1. Instalar Python 3 e dependências
2. Configurar conexões MySQL e SQLite
3. Testar a sincronização
4. Configurar execução automática via cron

## 📦 Instalação Manual

### 1. Instalar dependências

```bash
# Python 3
sudo apt-get install python3 python3-pip

# Biblioteca MySQL
pip3 install pymysql
```

Ou use o requirements.txt:

```bash
pip3 install -r requirements.txt
```

### 2. Copiar script

```bash
sudo cp mysql-to-sqlite-sync.py /usr/local/bin/
sudo chmod +x /usr/local/bin/mysql-to-sqlite-sync.py
```

### 3. Criar arquivo de configuração

```bash
sudo mkdir -p /etc/postfix/db
sudo cp sync-config.json.example /etc/postfix/db/sync-config.json
sudo nano /etc/postfix/db/sync-config.json
```

Edite com suas credenciais:

```json
{
  "mysql": {
    "host": "localhost",
    "port": 3306,
    "user": "root",
    "password": "sua_senha",
    "database": "mailserver"
  },
  "sqlite": {
    "path": "/etc/postfix/db/mailserver.db"
  }
}
```

```bash
# Proteger o arquivo (contém senha)
sudo chmod 600 /etc/postfix/db/sync-config.json
```

## 🔧 Uso

### Execução Manual

```bash
# Usando arquivo de configuração
python3 mysql-to-sqlite-sync.py -c /etc/postfix/db/sync-config.json

# Ou com o wrapper (após instalação)
sync-mail-db

# Usando argumentos da linha de comando
python3 mysql-to-sqlite-sync.py \
    --mysql-host localhost \
    --mysql-user root \
    --mysql-password senha123 \
    --mysql-database mailserver \
    --sqlite-path /etc/postfix/db/mailserver.db
```

### Ver Ajuda

```bash
python3 mysql-to-sqlite-sync.py --help
```

### Execução Automática (Cron)

Editar crontab:

```bash
crontab -e
```

Adicionar linha para sincronizar a cada 5 minutos:

```cron
*/5 * * * * /usr/bin/python3 /usr/local/bin/mysql-to-sqlite-sync.py -c /etc/postfix/db/sync-config.json >> /var/log/mysql-sqlite-sync.log 2>&1
```

Ou a cada 10 minutos:

```cron
*/10 * * * * /usr/bin/python3 /usr/local/bin/mysql-to-sqlite-sync.py -c /etc/postfix/db/sync-config.json >> /var/log/mysql-sqlite-sync.log 2>&1
```

Ou uma vez por hora:

```cron
0 * * * * /usr/bin/python3 /usr/local/bin/mysql-to-sqlite-sync.py -c /etc/postfix/db/sync-config.json >> /var/log/mysql-sqlite-sync.log 2>&1
```

## 📊 Estrutura das Tabelas

### MySQL (Origem)

```sql
-- tb_mail_domain
CREATE TABLE `tb_mail_domain` (
  `cd_domain` int(10) UNSIGNED NOT NULL,
  `domain` varchar(255) NOT NULL,
  `transport` varchar(45) NOT NULL,
  `created` datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  `active` tinyint(1) UNSIGNED NOT NULL,
  `storage_id` int(11) NOT NULL DEFAULT 1
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

-- tb_mail_mailbox
CREATE TABLE `tb_mail_mailbox` (
  `cd_mailbox` int(10) UNSIGNED NOT NULL,
  `username` varchar(255) NOT NULL,
  `password` varchar(100) NOT NULL,
  `domain` varchar(255) NOT NULL,
  `active` tinyint(1) UNSIGNED NOT NULL DEFAULT 1,
  `active_send` int(11) NOT NULL DEFAULT 1,
  `storage_id` int(11) NOT NULL DEFAULT 1
) ENGINE=MyISAM DEFAULT CHARSET=latin1;

-- tb_mail_alias
CREATE TABLE `tb_mail_alias` (
  `cd_alias` int(10) UNSIGNED NOT NULL,
  `address` varchar(255) NOT NULL,
  `goto` text NOT NULL,
  `domain` varchar(255) NOT NULL,
  `active` tinyint(1) UNSIGNED NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=latin1;
```

### SQLite (Destino)

O script mantém a mesma estrutura no SQLite, adaptando os tipos de dados conforme necessário.

## 📝 Como Funciona

### Fluxo de Sincronização

1. **Conexão**: Conecta aos dois bancos (MySQL e SQLite)
2. **Leitura**: Busca todos os registros de ambos os bancos
3. **Comparação**: Para cada registro do MySQL:
   - Se não existe no SQLite → **INSERT**
   - Se existe mas foi modificado → **UPDATE** (usando hash MD5)
   - Se existe e está igual → Ignora
4. **Commit**: Salva todas as alterações no SQLite
5. **Log**: Registra estatísticas da sincronização

### Detecção de Alterações

O script usa hash MD5 para detectar alterações:

```python
# Calcula hash do registro (excluindo chave primária)
row_hash = md5(json.dumps(row_data, sort_keys=True))

# Compara hashes
if mysql_hash != sqlite_hash:
    # Registro foi alterado - fazer UPDATE
```

Isso garante que apenas registros realmente modificados sejam atualizados.

## 📈 Logs

### Visualizar logs em tempo real

```bash
tail -f /var/log/mysql-sqlite-sync.log
```

### Exemplo de saída

```
2025-11-19 10:30:01 - INFO - ========================================
2025-11-19 10:30:01 - INFO - INICIANDO SINCRONIZAÇÃO MySQL -> SQLite
2025-11-19 10:30:01 - INFO - ========================================
2025-11-19 10:30:01 - INFO - Conectado ao MySQL: localhost:3306
2025-11-19 10:30:01 - INFO - Conectado ao SQLite: /etc/postfix/db/mailserver.db
2025-11-19 10:30:01 - INFO - === Sincronizando tb_mail_domain ===
2025-11-19 10:30:01 - INFO - MySQL: 5 registros encontrados em tb_mail_domain
2025-11-19 10:30:01 - INFO - SQLite: 3 registros encontrados em tb_mail_domain
2025-11-19 10:30:01 - INFO -   [INSERT] tb_mail_domain: cd_domain=4, domain=novo.com
2025-11-19 10:30:01 - INFO -   [INSERT] tb_mail_domain: cd_domain=5, domain=teste.com
2025-11-19 10:30:01 - INFO - === Sincronizando tb_mail_mailbox ===
2025-11-19 10:30:01 - INFO - MySQL: 12 registros encontrados em tb_mail_mailbox
2025-11-19 10:30:01 - INFO - SQLite: 10 registros encontrados em tb_mail_mailbox
2025-11-19 10:30:01 - INFO -   [INSERT] tb_mail_mailbox: cd_mailbox=11, username=user@novo.com
2025-11-19 10:30:01 - INFO -   [UPDATE] tb_mail_mailbox: cd_mailbox=5, username=admin@exemplo.com
2025-11-19 10:30:01 - INFO - === Sincronizando tb_mail_alias ===
2025-11-19 10:30:01 - INFO - MySQL: 8 registros encontrados em tb_mail_alias
2025-11-19 10:30:01 - INFO - SQLite: 8 registros encontrados em tb_mail_alias
2025-11-19 10:30:02 - INFO - ========================================
2025-11-19 10:30:02 - INFO - SINCRONIZAÇÃO CONCLUÍDA
2025-11-19 10:30:02 - INFO - ========================================
2025-11-19 10:30:02 - INFO - Registros inseridos:  3
2025-11-19 10:30:02 - INFO - Registros atualizados: 1
2025-11-19 10:30:02 - INFO - Registros inalterados: 16
2025-11-19 10:30:02 - INFO - Erros:                 0
2025-11-19 10:30:02 - INFO - Tempo de execução:     0.85 segundos
2025-11-19 10:30:02 - INFO - ========================================
```

### Rotação de Logs

O script de instalação configura logrotate automaticamente:

```
/var/log/mysql-sqlite-sync.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
```

## 🔍 Monitoramento

### Verificar se a sincronização está funcionando

```bash
# Ver última sincronização
tail -20 /var/log/mysql-sqlite-sync.log

# Ver estatísticas
grep "SINCRONIZAÇÃO CONCLUÍDA" /var/log/mysql-sqlite-sync.log | tail -5

# Ver erros
grep "ERROR" /var/log/mysql-sqlite-sync.log
```

### Verificar cron

```bash
# Listar tarefas agendadas
crontab -l

# Ver logs do cron
grep CRON /var/log/syslog | grep mysql-sqlite-sync
```

## 🐛 Troubleshooting

### Erro: "Access denied for user"

Verifique as credenciais do MySQL no arquivo de configuração:

```bash
# Testar conexão manualmente
mysql -h localhost -u root -p mailserver
```

### Erro: "database is locked"

O SQLite está sendo usado por outro processo:

```bash
# Ver processos usando o banco
lsof /etc/postfix/db/mailserver.db

# Aguardar e tentar novamente
```

### Erro: "table not found"

As tabelas não existem no SQLite. Execute o script de instalação do servidor SMTP primeiro:

```bash
./install-smtp-server.sh
```

### Sincronização não está rodando automaticamente

Verificar cron:

```bash
# Ver se o cron está ativo
systemctl status cron

# Reiniciar cron
systemctl restart cron

# Verificar logs
tail -f /var/log/syslog | grep CRON
```

## 🔒 Segurança

### Permissões de Arquivos

```bash
# Arquivo de configuração (contém senha)
chmod 600 /etc/postfix/db/sync-config.json
chown root:root /etc/postfix/db/sync-config.json

# Script
chmod 755 /usr/local/bin/mysql-to-sqlite-sync.py
chown root:root /usr/local/bin/mysql-to-sqlite-sync.py

# Banco SQLite
chmod 640 /etc/postfix/db/mailserver.db
chown postfix:postfix /etc/postfix/db/mailserver.db
```

### Conexão MySQL

Recomenda-se criar um usuário MySQL específico com permissões limitadas:

```sql
-- Criar usuário
CREATE USER 'mailsync'@'localhost' IDENTIFIED BY 'senha_forte';

-- Dar permissões apenas de leitura
GRANT SELECT ON mailserver.tb_mail_domain TO 'mailsync'@'localhost';
GRANT SELECT ON mailserver.tb_mail_mailbox TO 'mailsync'@'localhost';
GRANT SELECT ON mailserver.tb_mail_alias TO 'mailsync'@'localhost';

FLUSH PRIVILEGES;
```

Depois, atualize o arquivo de configuração:

```json
{
  "mysql": {
    "user": "mailsync",
    "password": "senha_forte"
  }
}
```

## 📊 Estatísticas

### Consultar registros sincronizados

```bash
# Contar registros no SQLite
sqlite3 /etc/postfix/db/mailserver.db "SELECT
  (SELECT COUNT(*) FROM tb_mail_domain) as domains,
  (SELECT COUNT(*) FROM tb_mail_mailbox) as mailboxes,
  (SELECT COUNT(*) FROM tb_mail_alias) as aliases;"
```

### Comparar MySQL vs SQLite

```bash
# MySQL
mysql -u root -p mailserver -e "
SELECT
  (SELECT COUNT(*) FROM tb_mail_domain) as domains,
  (SELECT COUNT(*) FROM tb_mail_mailbox) as mailboxes,
  (SELECT COUNT(*) FROM tb_mail_alias) as aliases;"

# SQLite
sqlite3 /etc/postfix/db/mailserver.db "
SELECT
  (SELECT COUNT(*) FROM tb_mail_domain) as domains,
  (SELECT COUNT(*) FROM tb_mail_mailbox) as mailboxes,
  (SELECT COUNT(*) FROM tb_mail_alias) as aliases;"
```

## 🔄 Sincronização Bidirecional

Este script sincroniza apenas MySQL → SQLite (unidirecional).

Para sincronização bidirecional (SQLite → MySQL), seria necessário:

- Implementar log de alterações no SQLite
- Detectar conflitos de dados
- Definir estratégia de resolução de conflitos

## 📚 Referências

- [PyMySQL Documentation](https://pymysql.readthedocs.io/)
- [SQLite3 Python](https://docs.python.org/3/library/sqlite3.html)
- [Postfix SQLite](http://www.postfix.org/sqlite_table.5.html)

## 📝 Licença

Este script é fornecido "como está", sem garantias.

---

**Desenvolvido para sincronização de servidor de email Postfix + SQLite**
