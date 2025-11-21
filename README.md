# Servidor SMTP (Somente Envio)

Script de instalação automatizada de servidor SMTP configurado apenas para envio de emails, usando:

- **Postfix** - Servidor SMTP
- **Dovecot** - Autenticação SASL
- **SQLite** - Banco de dados para usuários e domínios
- **OpenDKIM** - Assinatura DKIM
- **Lego** - Certificados SSL/TLS Let's Encrypt

## 📋 Requisitos

- Sistema operacional: Ubuntu/Debian (testado em Ubuntu 20.04+)
- Acesso root
- Servidor com IP público estático
- Portas abertas: 25, 587, 80 (para geração de certificado)
- Domínio configurado apontando para o servidor

## 🚀 Instalação

### 1. Download e permissões

```bash
# Fazer download do script
wget https://raw.githubusercontent.com/seu-repo/install-smtp-server.sh

# Ou se já estiver no diretório
chmod +x install-smtp-server.sh
```

### 2. Executar como root

```bash
sudo ./install-smtp-server.sh
```

### 3. Informações solicitadas durante a instalação

O script irá solicitar:

- **Hostname**: Ex: `mail.seudominio.com`
- **Domínio principal**: Ex: `seudominio.com`
- **Email administrativo**: Para notificações e certificado SSL
- **Relayhost** (opcional): Para usar serviços como Amazon SES, SendGrid, Mailgun

#### Exemplos de Relayhost

```
Amazon SES:     email-smtp.us-east-1.amazonaws.com:587
SendGrid:       smtp.sendgrid.net:587
Mailgun:        smtp.mailgun.org:587
SMTP Customizado: smtp.exemplo.com:587
```

## 📊 Estrutura do Banco de Dados

O script cria automaticamente um banco SQLite com as seguintes tabelas:

### tb_mail_domain

```sql
cd_domain       INTEGER PRIMARY KEY
domain          VARCHAR(255) UNIQUE
transport       VARCHAR(45)
created         DATETIME
active          INTEGER
storage_id      INTEGER
```

### tb_mail_mailbox

```sql
cd_mailbox      INTEGER PRIMARY KEY
username        VARCHAR(255) UNIQUE
password        VARCHAR(100)
domain          VARCHAR(255)
active          INTEGER
active_send     INTEGER
storage_id      INTEGER
```

### tb_mail_alias

```sql
cd_alias        INTEGER PRIMARY KEY
address         VARCHAR(255)
goto            TEXT
domain          VARCHAR(255)
active          INTEGER
```

## 🛠️ Scripts de Gerenciamento

Após a instalação, os seguintes comandos estarão disponíveis:

### Adicionar Domínio

```bash
smtp-add-domain.sh novodominio.com
```

Este comando:

- Adiciona o domínio ao banco de dados
- Gera chaves DKIM para o domínio
- Atualiza configurações do OpenDKIM
- Exibe o registro DNS TXT para DKIM

### Adicionar Usuário

```bash
smtp-add-user.sh usuario@dominio.com senha123
```

### Listar Usuários

```bash
smtp-list-users.sh
```

### Verificar Configuração

```bash
smtp-check-config.sh
```

Exibe:

- Status dos serviços
- Portas em escuta
- Domínios configurados
- Usuários cadastrados
- Logs recentes

## 🌐 Configuração DNS

Após a instalação, um arquivo `/root/CONFIGURACAO_DNS.txt` será criado com todas as configurações necessárias.

### Registros Obrigatórios

#### 1. Registro A

```
Nome: mail
Tipo: A
Valor: SEU_IP_PUBLICO
TTL: 3600
```

#### 2. Registro MX

```
Nome: @
Tipo: MX
Prioridade: 10
Valor: mail.seudominio.com
TTL: 3600
```

#### 3. Registro SPF (TXT)

```
Nome: @
Tipo: TXT
Valor: v=spf1 mx a:mail.seudominio.com -all
TTL: 3600
```

**Opções de SPF:**

- `-all` - Rejeita emails de outros servidores (recomendado)
- `~all` - Soft fail (marca como suspeito, mas não rejeita)
- `+all` - Permite todos (NÃO RECOMENDADO)

#### 4. Registro DKIM (TXT)

```
Nome: mail._domainkey
Tipo: TXT
Valor: [será exibido após a instalação]
TTL: 3600
```

#### 5. Registro DMARC (TXT)

```
Nome: _dmarc
Tipo: TXT
Valor: v=DMARC1; p=quarantine; rua=mailto:admin@seudominio.com; ruf=mailto:admin@seudominio.com; fo=1; adkim=s; aspf=s; pct=100
TTL: 3600
```

**Políticas DMARC:**

- `p=none` - Monitoramento apenas (recomendado inicialmente)
- `p=quarantine` - Coloca emails suspeitos em spam
- `p=reject` - Rejeita emails que falham na validação

#### 6. Registro PTR (Reverse DNS) ⚠️ CRÍTICO

Configure com seu provedor de VPS/Cloud:

```
IP: SEU_IP_PUBLICO
PTR: mail.seudominio.com
```

**Sem PTR correto, a maioria dos servidores rejeitará seus emails!**

## 📧 Testando o Servidor

### 1. Teste básico de conexão

```bash
telnet mail.seudominio.com 587
```

### 2. Enviar email de teste

```bash
# Instalar mailutils se necessário
apt-get install mailutils

# Enviar email
echo "Corpo do email" | mail -s "Assunto" -a "From: usuario@seudominio.com" destino@exemplo.com
```

### 3. Teste com autenticação SMTP

```bash
# Criar arquivo de teste
cat > /tmp/email-teste.txt << EOF
EHLO mail.seudominio.com
AUTH LOGIN
$(echo -n "usuario@seudominio.com" | base64)
$(echo -n "sua_senha" | base64)
MAIL FROM:<usuario@seudominio.com>
RCPT TO:<destino@exemplo.com>
DATA
Subject: Teste de Email
From: usuario@seudominio.com
To: destino@exemplo.com

Este é um email de teste.
.
QUIT
EOF

# Enviar via telnet
cat /tmp/email-teste.txt | telnet mail.seudominio.com 587
```

### 4. Ferramentas online de teste

- **MXToolbox**: https://mxtoolbox.com/SuperTool.aspx
- **Mail Tester**: https://www.mail-tester.com/
- **DKIM Validator**: https://dkimvalidator.com/
- **DMARCian**: https://dmarcian.com/domain-checker/

## 📁 Arquivos e Diretórios Importantes

```
/etc/postfix/
├── main.cf                 # Configuração principal do Postfix
├── master.cf              # Configuração de serviços do Postfix
├── sasl_passwd            # Credenciais de relayhost (se configurado)
└── db/
    ├── mailserver.db      # Banco de dados SQLite
    └── sqlite-*.cf        # Queries SQL do Postfix

/etc/dovecot/
├── dovecot.conf           # Configuração principal do Dovecot
└── dovecot-sql.conf.ext   # Configuração SQL do Dovecot

/etc/opendkim/
├── opendkim.conf          # Configuração do OpenDKIM
├── key.table              # Tabela de chaves DKIM
├── signing.table          # Tabela de assinatura
├── trusted.hosts          # Hosts confiáveis
└── keys/
    └── [dominio].private  # Chaves privadas DKIM

/etc/lego/certificates/
├── [hostname].crt         # Certificado SSL
└── [hostname].key         # Chave privada SSL

/var/log/
├── mail.log               # Logs do Postfix
└── dovecot.log           # Logs do Dovecot
```

## 🔧 Manutenção

### Renovar Certificado SSL

```bash
lego --email="admin@seudominio.com" \
     --domains="mail.seudominio.com" \
     --path="/etc/lego" \
     renew

systemctl reload postfix
```

### Adicionar renovação automática ao cron

```bash
# Editar crontab
crontab -e

# Adicionar linha (roda todo dia às 3h)
0 3 * * * /usr/local/bin/lego --email="admin@seudominio.com" --domains="mail.seudominio.com" --path="/etc/lego" renew && systemctl reload postfix
```

### Monitorar Logs

```bash
# Logs em tempo real
tail -f /var/log/mail.log

# Buscar erros
grep -i error /var/log/mail.log

# Buscar por email específico
grep "usuario@dominio.com" /var/log/mail.log
```

### Verificar Fila de Emails

```bash
# Ver fila
postqueue -p

# Processar fila manualmente
postqueue -f

# Limpar fila (CUIDADO!)
postsuper -d ALL
```

### Backup do Banco de Dados

```bash
# Criar backup
sqlite3 /etc/postfix/db/mailserver.db .dump > /root/backup-mail-$(date +%Y%m%d).sql

# Restaurar backup
sqlite3 /etc/postfix/db/mailserver.db < /root/backup-mail-20231118.sql
```

## 🔒 Segurança

### Recomendações

1. **Firewall**: Configure para permitir apenas portas necessárias

```bash
ufw allow 22/tcp    # SSH
ufw allow 25/tcp    # SMTP
ufw allow 587/tcp   # Submission
ufw enable
```

2. **Fail2ban**: Proteja contra ataques de força bruta

```bash
apt-get install fail2ban
```

3. **Senhas**: Use senhas fortes para usuários SMTP

4. **Monitoramento**: Configure alertas para logs suspeitos

5. **Rate Limiting**: Configure limites de envio no Postfix

```bash
# Adicionar ao main.cf
smtpd_client_connection_rate_limit = 10
smtpd_client_message_rate_limit = 100
```

## 🐛 Troubleshooting

### Porta 587 não está escutando

```bash
systemctl status postfix
netstat -tuln | grep 587
journalctl -u postfix -n 50
```

### Autenticação SASL falhando

```bash
# Verificar Dovecot
systemctl status dovecot
tail -f /var/log/dovecot.log

# Testar query SQL
sqlite3 /etc/postfix/db/mailserver.db "SELECT * FROM tb_mail_mailbox WHERE username='usuario@dominio.com';"
```

### OpenDKIM não está assinando

```bash
# Verificar serviço
systemctl status opendkim

# Testar assinatura
opendkim-testkey -d seudominio.com -s mail -vvv

# Verificar logs
tail -f /var/log/mail.log | grep dkim
```

### Certificado SSL inválido

```bash
# Verificar certificado
openssl x509 -in /etc/lego/certificates/mail.seudominio.com.crt -text -noout

# Regenerar
lego --email="admin@seudominio.com" \
     --domains="mail.seudominio.com" \
     --path="/etc/lego" \
     --accept-tos \
     run --force
```

### Emails sendo rejeitados

1. Verificar PTR (Reverse DNS)

```bash
dig -x SEU_IP_PUBLICO +short
```

2. Verificar SPF

```bash
dig +short TXT seudominio.com | grep spf
```

3. Verificar DKIM

```bash
dig +short TXT mail._domainkey.seudominio.com
```

4. Verificar DMARC

```bash
dig +short TXT _dmarc.seudominio.com
```

5. Testar em mail-tester.com

## 📊 Operações Diretas no SQLite

### Listar todos os domínios

```bash
sqlite3 /etc/postfix/db/mailserver.db "SELECT * FROM tb_mail_domain;"
```

### Listar todos os usuários

```bash
sqlite3 /etc/postfix/db/mailserver.db "SELECT username, domain, active, active_send FROM tb_mail_mailbox;"
```

### Desabilitar envio de um usuário

```bash
sqlite3 /etc/postfix/db/mailserver.db "UPDATE tb_mail_mailbox SET active_send=0 WHERE username='usuario@dominio.com';"
```

### Adicionar alias

```bash
sqlite3 /etc/postfix/db/mailserver.db "INSERT INTO tb_mail_alias (address, goto, domain, active) VALUES ('vendas@dominio.com', 'joao@dominio.com,maria@dominio.com', 'dominio.com', 1);"
```

### Alterar senha de usuário

```bash
sqlite3 /etc/postfix/db/mailserver.db "UPDATE tb_mail_mailbox SET password='nova_senha_123' WHERE username='usuario@dominio.com';"
```

## 📚 Recursos Adicionais

- [Postfix Documentation](http://www.postfix.org/documentation.html)
- [Dovecot Documentation](https://doc.dovecot.org/)
- [OpenDKIM Documentation](http://www.opendkim.org/)
- [SPF Record Syntax](https://www.rfc-editor.org/rfc/rfc7208)
- [DMARC Overview](https://dmarc.org/)

## 📝 Licença

Este script é fornecido "como está", sem garantias de qualquer tipo.

## 🤝 Contribuindo

Sugestões e melhorias são bem-vindas!

---

**⚠️ IMPORTANTE**: Configure todos os registros DNS antes de começar a enviar emails em produção para evitar que seus emails sejam marcados como spam!
