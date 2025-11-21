#!/bin/bash

################################################################################
# Script de Instalação de Servidor SMTP (Somente Envio)
# Postfix + Dovecot + SQLite + OpenDKIM + TLS (Lego)
################################################################################

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Função de log
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    log_error "Este script deve ser executado como root"
    exit 1
fi

################################################################################
# CONFIGURAÇÕES INICIAIS
################################################################################

echo "========================================================================"
echo "  INSTALAÇÃO DE SERVIDOR SMTP (SOMENTE ENVIO)"
echo "========================================================================"
echo ""

# Coletar informações
read -p "Digite o hostname do servidor (ex: mail.exemplo.com): " HOSTNAME
read -p "Digite o domínio principal (ex: exemplo.com): " MAIN_DOMAIN
read -p "Digite o email para notificações e certificado SSL: " ADMIN_EMAIL
read -p "Deseja configurar um relayhost? (s/N): " USE_RELAYHOST

RELAYHOST=""
RELAYHOST_USER=""
RELAYHOST_PASS=""

if [[ "$USE_RELAYHOST" =~ ^[sS]$ ]]; then
    echo ""
    echo "Exemplos de relayhost:"
    echo "  - Amazon SES: email-smtp.us-east-1.amazonaws.com:587"
    echo "  - SendGrid: smtp.sendgrid.net:587"
    echo "  - Mailgun: smtp.mailgun.org:587"
    echo "  - Outro SMTP: smtp.exemplo.com:587"
    echo ""
    read -p "Digite o relayhost (host:porta): " RELAYHOST
    read -p "Digite o usuário do relayhost: " RELAYHOST_USER
    read -sp "Digite a senha do relayhost: " RELAYHOST_PASS
    echo ""
fi

# Diretórios
DB_DIR="/etc/postfix/db"
DKIM_DIR="/etc/opendkim"
SSL_DIR="/etc/lego/certificates"

log_info "Iniciando instalação..."

################################################################################
# INSTALAÇÃO DE PACOTES
################################################################################

log_info "Atualizando sistema e instalando pacotes necessários..."

apt-get update
apt-get install -y \
    postfix \
    dovecot-core \
    dovecot-sqlite \
    sqlite3 \
    opendkim \
    opendkim-tools \
    mailutils \
    wget \
    curl \
    ca-certificates

################################################################################
# INSTALAÇÃO DO LEGO (Let's Encrypt Client)
################################################################################

log_info "Instalando Lego para geração de certificados SSL..."

LEGO_VERSION="4.28.1"
wget -q "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/lego_v${LEGO_VERSION}_linux_amd64.tar.gz" -O /tmp/lego.tar.gz
tar -xzf /tmp/lego.tar.gz -C /usr/local/bin lego
chmod +x /usr/local/bin/lego
rm /tmp/lego.tar.gz

################################################################################
# CONFIGURAÇÃO DO HOSTNAME
################################################################################

log_info "Configurando hostname..."

hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname

# Adicionar ao /etc/hosts se não existir
if ! grep -q "$HOSTNAME" /etc/hosts; then
    echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
fi

################################################################################
# CRIAÇÃO DO BANCO DE DADOS SQLITE
################################################################################

log_info "Criando banco de dados SQLite..."

mkdir -p "$DB_DIR"

cat > "$DB_DIR/schema.sql" << 'EOF'
-- Tabela de domínios
CREATE TABLE IF NOT EXISTS tb_mail_domain (
  cd_domain INTEGER PRIMARY KEY AUTOINCREMENT,
  domain VARCHAR(255) NOT NULL UNIQUE,
  transport VARCHAR(45) NOT NULL DEFAULT 'virtual',
  created DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  active INTEGER NOT NULL DEFAULT 1,
  storage_id INTEGER NOT NULL DEFAULT 1
);

-- Tabela de mailboxes (usuários)
CREATE TABLE IF NOT EXISTS tb_mail_mailbox (
  cd_mailbox INTEGER PRIMARY KEY AUTOINCREMENT,
  username VARCHAR(255) NOT NULL UNIQUE,
  password VARCHAR(100) NOT NULL,
  domain VARCHAR(255) NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  active_send INTEGER NOT NULL DEFAULT 1,
  storage_id INTEGER NOT NULL DEFAULT 1,
  FOREIGN KEY (domain) REFERENCES tb_mail_domain(domain)
);

-- Tabela de alias
CREATE TABLE IF NOT EXISTS tb_mail_alias (
  cd_alias INTEGER PRIMARY KEY AUTOINCREMENT,
  address VARCHAR(255) NOT NULL,
  goto TEXT NOT NULL,
  domain VARCHAR(255) NOT NULL,
  active INTEGER NOT NULL DEFAULT 1,
  UNIQUE(address, domain)
);

-- Inserir domínio padrão
INSERT OR IGNORE INTO tb_mail_domain (domain, transport, active) 
VALUES ('${MAIN_DOMAIN}', 'virtual', 1);
EOF

# Criar banco de dados
sqlite3 "$DB_DIR/mailserver.db" < "$DB_DIR/schema.sql"

# Ajustar permissões
chown -R postfix:postfix "$DB_DIR"
chmod 750 "$DB_DIR"
chmod 640 "$DB_DIR/mailserver.db"

log_info "Banco de dados criado em: $DB_DIR/mailserver.db"

################################################################################
# GERAÇÃO DE CERTIFICADO SSL COM LEGO
################################################################################

log_info "Gerando certificado SSL com Let's Encrypt..."

mkdir -p "$SSL_DIR"

# Verificar se a porta 80 está disponível
if netstat -tuln | grep -q ':80 '; then
    log_warn "Porta 80 está em uso. Certifique-se de que o servidor web está parado temporariamente."
    log_warn "Tentando gerar certificado mesmo assim..."
fi

# Gerar certificado
lego --email="$ADMIN_EMAIL" \
     --domains="$HOSTNAME" \
     --path="/etc/lego" \
     --accept-tos \
     run || {
    log_warn "Falha ao gerar certificado automaticamente."
    log_warn "Você precisará configurar o certificado manualmente ou usar certbot."
    log_warn "Criando certificado auto-assinado temporário..."
    
    # Criar certificado auto-assinado como fallback
    mkdir -p /etc/ssl/private
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/ssl/private/postfix.key \
        -out /etc/ssl/certs/postfix.crt \
        -subj "/CN=$HOSTNAME"
    
    SSL_CERT="/etc/ssl/certs/postfix.crt"
    SSL_KEY="/etc/ssl/private/postfix.key"
}

# Definir caminhos dos certificados
if [ -f "/etc/lego/certificates/${HOSTNAME}.crt" ]; then
    SSL_CERT="/etc/lego/certificates/${HOSTNAME}.crt"
    SSL_KEY="/etc/lego/certificates/${HOSTNAME}.key"
else
    SSL_CERT="/etc/ssl/certs/postfix.crt"
    SSL_KEY="/etc/ssl/private/postfix.key"
fi

################################################################################
# CONFIGURAÇÃO DO DOVECOT (SASL Authentication)
################################################################################

log_info "Configurando Dovecot para autenticação SASL..."

# Backup das configurações originais
cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.backup

# Configuração principal do Dovecot
cat > /etc/dovecot/dovecot.conf << 'EOF'
# Dovecot configuration for SMTP AUTH only (no mail storage)

protocols = 

# Configurações de autenticação
disable_plaintext_auth = no
auth_mechanisms = plain login

# Não precisamos de mail_location pois é apenas SMTP
# mail_location = 

# Log
log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log
debug_log_path = /var/log/dovecot-debug.log

# SSL (não usado no SASL, mas pode ser útil)
ssl = no

# Incluir configurações adicionais
!include conf.d/*.conf
EOF

# Configuração de autenticação SQL
cat > /etc/dovecot/dovecot-sql.conf.ext << EOF
driver = sqlite
connect = $DB_DIR/mailserver.db

# Query para autenticação
password_query = SELECT username as user, password FROM tb_mail_mailbox WHERE username='%u' AND active=1 AND active_send=1

# Query para informações do usuário
user_query = SELECT username as user FROM tb_mail_mailbox WHERE username='%u' AND active=1

# Scheme de senha (usar PLAIN ou crypt dependendo de como as senhas são armazenadas)
default_pass_scheme = PLAIN
EOF

chmod 640 /etc/dovecot/dovecot-sql.conf.ext
chown root:dovecot /etc/dovecot/dovecot-sql.conf.ext

# Configuração de autenticação
cat > /etc/dovecot/conf.d/10-auth.conf << 'EOF'
# Desabilitar autenticação do sistema
!include auth-system.conf.ext

# Habilitar autenticação SQL
!include auth-sql.conf.ext
EOF

# Arquivo de autenticação SQL
cat > /etc/dovecot/conf.d/auth-sql.conf.ext << 'EOF'
passdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}

userdb {
  driver = sql
  args = /etc/dovecot/dovecot-sql.conf.ext
}
EOF

# Configuração do serviço de autenticação
cat > /etc/dovecot/conf.d/10-master.conf << 'EOF'
service auth {
  # Postfix smtp-auth
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
}

service auth-worker {
  user = $default_internal_user
}
EOF

################################################################################
# CONFIGURAÇÃO DO OPENDKIM
################################################################################

log_info "Configurando OpenDKIM..."

mkdir -p "$DKIM_DIR/keys"

# Configuração principal
cat > /etc/opendkim.conf << EOF
# OpenDKIM Configuration

Syslog                  yes
SyslogSuccess           yes
LogWhy                  yes

# Modo de operação
Mode                    sv
SubDomains              no

# Canonicalização
Canonicalization        relaxed/simple

# Selector
Selector                mail

# Key e domínios
KeyTable                refile:$DKIM_DIR/key.table
SigningTable            refile:$DKIM_DIR/signing.table
ExternalIgnoreList      refile:$DKIM_DIR/trusted.hosts
InternalHosts           refile:$DKIM_DIR/trusted.hosts

# Socket para Postfix
Socket                  inet:8891@localhost
PidFile                 /var/run/opendkim/opendkim.pid
UserID                  opendkim:opendkim
UMask                   002

# Configurações de assinatura
OversignHeaders         From
EOF

# Criar chave DKIM para o domínio principal
opendkim-genkey -b 2048 -d "$MAIN_DOMAIN" -D "$DKIM_DIR/keys" -s mail -v

# Renomear arquivos
mv "$DKIM_DIR/keys/mail.private" "$DKIM_DIR/keys/${MAIN_DOMAIN}.private"
mv "$DKIM_DIR/keys/mail.txt" "$DKIM_DIR/keys/${MAIN_DOMAIN}.txt"

# Configurar permissões
chown -R opendkim:opendkim "$DKIM_DIR"
chmod 640 "$DKIM_DIR/keys/${MAIN_DOMAIN}.private"

# Key table
cat > "$DKIM_DIR/key.table" << EOF
mail._domainkey.$MAIN_DOMAIN $MAIN_DOMAIN:mail:$DKIM_DIR/keys/${MAIN_DOMAIN}.private
EOF

# Signing table
cat > "$DKIM_DIR/signing.table" << EOF
*@$MAIN_DOMAIN mail._domainkey.$MAIN_DOMAIN
EOF

# Trusted hosts
cat > "$DKIM_DIR/trusted.hosts" << EOF
127.0.0.1
localhost
$HOSTNAME
$MAIN_DOMAIN
EOF

################################################################################
# CONFIGURAÇÃO DO POSTFIX
################################################################################

log_info "Configurando Postfix..."

# Backup da configuração original
if [ -f /etc/postfix/main.cf ]; then
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup
fi

# Configuração principal do Postfix
cat > /etc/postfix/main.cf << EOF
# Configurações básicas
myhostname = $HOSTNAME
mydomain = $MAIN_DOMAIN
myorigin = \$mydomain
mydestination = localhost
relayhost = $RELAYHOST

# Interface de rede
inet_interfaces = all
inet_protocols = ipv4

# Configurações de relay
mynetworks = 127.0.0.0/8
relay_domains = 

# TLS/SSL para conexões de saída
smtp_use_tls = yes
smtp_tls_security_level = may
smtp_tls_loglevel = 1

# TLS/SSL para submission (porta 587)
smtpd_use_tls = yes
smtpd_tls_security_level = encrypt
smtpd_tls_cert_file = $SSL_CERT
smtpd_tls_key_file = $SSL_KEY
smtpd_tls_session_cache_database = btree:\${data_directory}/smtpd_scache
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# Autenticação SASL via Dovecot
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$mydomain
broken_sasl_auth_clients = yes

# Restrições de relay
smtpd_relay_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination

# Restrições de recepção (mais restritivas para servidor apenas envio)
smtpd_recipient_restrictions = 
    permit_mynetworks,
    permit_sasl_authenticated,
    reject_unauth_destination,
    reject_invalid_hostname,
    reject_non_fqdn_hostname,
    reject_non_fqdn_sender,
    reject_non_fqdn_recipient,
    reject_unknown_sender_domain,
    reject_unknown_recipient_domain

# OpenDKIM
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:8891
non_smtpd_milters = inet:localhost:8891

# SQLite para domínios e usuários
virtual_mailbox_domains = sqlite:$DB_DIR/sqlite-virtual-mailbox-domains.cf
virtual_mailbox_maps = sqlite:$DB_DIR/sqlite-virtual-mailbox-maps.cf
virtual_alias_maps = sqlite:$DB_DIR/sqlite-virtual-alias-maps.cf

# Configurações de mensagem
message_size_limit = 20971520
mailbox_size_limit = 0

# Segurança adicional
smtpd_helo_required = yes
disable_vrfy_command = yes

# Compatibilidade
compatibility_level = 2
EOF

# Configuração de domínios virtuais
cat > "$DB_DIR/sqlite-virtual-mailbox-domains.cf" << EOF
dbpath = $DB_DIR/mailserver.db
query = SELECT domain FROM tb_mail_domain WHERE domain='%s' AND active=1
EOF

# Configuração de mailboxes virtuais
cat > "$DB_DIR/sqlite-virtual-mailbox-maps.cf" << EOF
dbpath = $DB_DIR/mailserver.db
query = SELECT username FROM tb_mail_mailbox WHERE username='%s' AND active=1
EOF

# Configuração de alias virtuais
cat > "$DB_DIR/sqlite-virtual-alias-maps.cf" << EOF
dbpath = $DB_DIR/mailserver.db
query = SELECT goto FROM tb_mail_alias WHERE address='%s' AND active=1
EOF

# Ajustar permissões
chmod 640 "$DB_DIR"/sqlite-*.cf
chown postfix:postfix "$DB_DIR"/sqlite-*.cf

# Configuração do master.cf (submission na porta 587)
cat > /etc/postfix/master.cf << 'EOF'
# Postfix master process configuration

# Service type  private unpriv  chroot  wakeup  maxproc command + args
smtp      inet  n       -       y       -       -       smtpd

# Submission (porta 587) - requer autenticação
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_relay_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
EOF

# Configurar autenticação de relayhost se necessário
if [ -n "$RELAYHOST" ] && [ -n "$RELAYHOST_USER" ]; then
    log_info "Configurando autenticação de relayhost..."
    
    cat > /etc/postfix/sasl_passwd << EOF
$RELAYHOST $RELAYHOST_USER:$RELAYHOST_PASS
EOF
    
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    
    # Adicionar ao main.cf
    echo "" >> /etc/postfix/main.cf
    echo "# Autenticação de relayhost" >> /etc/postfix/main.cf
    echo "smtp_sasl_auth_enable = yes" >> /etc/postfix/main.cf
    echo "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd" >> /etc/postfix/main.cf
    echo "smtp_sasl_security_options = noanonymous" >> /etc/postfix/main.cf
fi

################################################################################
# CRIAR SCRIPTS DE GERENCIAMENTO
################################################################################

log_info "Criando scripts de gerenciamento..."

# Script para adicionar domínio
cat > /usr/local/bin/smtp-add-domain.sh << 'SCRIPT_EOF'
#!/bin/bash
DB="/etc/postfix/db/mailserver.db"
DKIM_DIR="/etc/opendkim"

if [ $# -ne 1 ]; then
    echo "Uso: $0 <dominio>"
    exit 1
fi

DOMAIN=$1

# Adicionar ao banco
sqlite3 $DB "INSERT INTO tb_mail_domain (domain, transport, active) VALUES ('$DOMAIN', 'virtual', 1);"

# Gerar chave DKIM
opendkim-genkey -b 2048 -d "$DOMAIN" -D "$DKIM_DIR/keys" -s mail -v
mv "$DKIM_DIR/keys/mail.private" "$DKIM_DIR/keys/${DOMAIN}.private"
mv "$DKIM_DIR/keys/mail.txt" "$DKIM_DIR/keys/${DOMAIN}.txt"

# Atualizar configurações DKIM
echo "mail._domainkey.$DOMAIN $DOMAIN:mail:$DKIM_DIR/keys/${DOMAIN}.private" >> $DKIM_DIR/key.table
echo "*@$DOMAIN mail._domainkey.$DOMAIN" >> $DKIM_DIR/signing.table
echo "$DOMAIN" >> $DKIM_DIR/trusted.hosts

chown -R opendkim:opendkim "$DKIM_DIR"
chmod 640 "$DKIM_DIR/keys/${DOMAIN}.private"

echo "Domínio $DOMAIN adicionado!"
echo ""
echo "Adicione este registro DNS TXT para DKIM:"
cat "$DKIM_DIR/keys/${DOMAIN}.txt"

systemctl reload opendkim
systemctl reload postfix
SCRIPT_EOF

chmod +x /usr/local/bin/smtp-add-domain.sh

# Script para adicionar usuário
cat > /usr/local/bin/smtp-add-user.sh << 'SCRIPT_EOF'
#!/bin/bash
DB="/etc/postfix/db/mailserver.db"

if [ $# -ne 2 ]; then
    echo "Uso: $0 <email> <senha>"
    exit 1
fi

EMAIL=$1
PASSWORD=$2
DOMAIN=$(echo $EMAIL | cut -d@ -f2)

# Verificar se o domínio existe
DOMAIN_EXISTS=$(sqlite3 $DB "SELECT COUNT(*) FROM tb_mail_domain WHERE domain='$DOMAIN' AND active=1;")

if [ "$DOMAIN_EXISTS" -eq 0 ]; then
    echo "Erro: Domínio $DOMAIN não existe. Adicione-o primeiro com smtp-add-domain.sh"
    exit 1
fi

# Adicionar usuário
sqlite3 $DB "INSERT INTO tb_mail_mailbox (username, password, domain, active, active_send) VALUES ('$EMAIL', '$PASSWORD', '$DOMAIN', 1, 1);"

echo "Usuário $EMAIL adicionado com sucesso!"
SCRIPT_EOF

chmod +x /usr/local/bin/smtp-add-user.sh

# Script para listar usuários
cat > /usr/local/bin/smtp-list-users.sh << 'SCRIPT_EOF'
#!/bin/bash
DB="/etc/postfix/db/mailserver.db"

echo "=== Usuários cadastrados ==="
sqlite3 -header -column $DB "SELECT cd_mailbox as ID, username as Email, domain as Dominio, active as Ativo, active_send as 'Envio Ativo' FROM tb_mail_mailbox;"
SCRIPT_EOF

chmod +x /usr/local/bin/smtp-list-users.sh

# Script para verificar configuração
cat > /usr/local/bin/smtp-check-config.sh << 'SCRIPT_EOF'
#!/bin/bash

echo "========================================================================"
echo "  VERIFICAÇÃO DE CONFIGURAÇÃO DO SERVIDOR SMTP"
echo "========================================================================"
echo ""

echo "=== Status dos Serviços ==="
systemctl status postfix --no-pager | head -3
systemctl status dovecot --no-pager | head -3
systemctl status opendkim --no-pager | head -3
echo ""

echo "=== Portas em Escuta ==="
netstat -tuln | grep -E ':(25|587|8891) '
echo ""

echo "=== Domínios Configurados ==="
sqlite3 -header -column /etc/postfix/db/mailserver.db "SELECT domain, active FROM tb_mail_domain;"
echo ""

echo "=== Usuários Configurados ==="
sqlite3 -header -column /etc/postfix/db/mailserver.db "SELECT username, domain, active FROM tb_mail_mailbox;"
echo ""

echo "=== Teste de Autenticação SASL ==="
testsaslauthd -f /var/spool/postfix/private/auth -s smtp || echo "Teste direto não disponível"
echo ""

echo "=== Últimas linhas do log do Postfix ==="
tail -n 10 /var/log/mail.log 2>/dev/null || tail -n 10 /var/log/syslog | grep postfix
echo ""
SCRIPT_EOF

chmod +x /usr/local/bin/smtp-check-config.sh

################################################################################
# CRIAR GUIA DE CONFIGURAÇÃO DNS
################################################################################

log_info "Criando guia de configuração DNS..."

cat > /root/CONFIGURACAO_DNS.txt << EOF
======================================================================
  CONFIGURAÇÃO DNS NECESSÁRIA PARA $MAIN_DOMAIN
======================================================================

1. REGISTRO A
   ---------------------------------------------------------------------
   Nome: mail (ou @ se for usar o domínio principal)
   Tipo: A
   Valor: $(curl -s ifconfig.me || echo "SEU_IP_PUBLICO")
   TTL: 3600

2. REGISTRO MX
   ---------------------------------------------------------------------
   Nome: @
   Tipo: MX
   Prioridade: 10
   Valor: $HOSTNAME
   TTL: 3600

3. REGISTRO SPF (TXT)
   ---------------------------------------------------------------------
   Nome: @
   Tipo: TXT
   Valor: v=spf1 mx a:$HOSTNAME -all
   TTL: 3600
   
   Explicação:
   - v=spf1: Versão do SPF
   - mx: Permite servidores listados no MX
   - a:$HOSTNAME: Permite o IP do hostname
   - -all: Rejeita todos os outros (use ~all para soft fail)

4. REGISTRO DKIM (TXT)
   ---------------------------------------------------------------------
   Nome: mail._domainkey
   Tipo: TXT
   Valor: $(cat $DKIM_DIR/keys/${MAIN_DOMAIN}.txt | grep -oP 'v=DKIM1.*' | tr -d '\n' | tr -d '"')
   TTL: 3600
   
   Arquivo completo: $DKIM_DIR/keys/${MAIN_DOMAIN}.txt

5. REGISTRO DMARC (TXT)
   ---------------------------------------------------------------------
   Nome: _dmarc
   Tipo: TXT
   Valor: v=DMARC1; p=quarantine; rua=mailto:$ADMIN_EMAIL; ruf=mailto:$ADMIN_EMAIL; fo=1; adkim=s; aspf=s; pct=100
   TTL: 3600
   
   Explicação:
   - p=quarantine: Coloca emails suspeitos em quarentena (use p=reject para rejeitar)
   - rua: Email para receber relatórios agregados
   - ruf: Email para receber relatórios forenses
   - fo=1: Gera relatórios se DKIM ou SPF falhar
   - adkim=s: DKIM strict (deve corresponder exatamente)
   - aspf=s: SPF strict (deve corresponder exatamente)
   - pct=100: Aplica política a 100% dos emails

6. REGISTRO PTR (Reverse DNS) - IMPORTANTE!
   ---------------------------------------------------------------------
   Configure com seu provedor de VPS/servidor:
   IP: $(curl -s ifconfig.me || echo "SEU_IP_PUBLICO")
   PTR: $HOSTNAME
   
   Sem PTR correto, muitos servidores rejeitarão seus emails!

======================================================================
  VALIDAÇÃO DAS CONFIGURAÇÕES
======================================================================

Após configurar o DNS, aguarde a propagação (até 48h) e teste:

1. Verificar SPF:
   dig +short TXT $MAIN_DOMAIN | grep spf

2. Verificar DKIM:
   dig +short TXT mail._domainkey.$MAIN_DOMAIN

3. Verificar DMARC:
   dig +short TXT _dmarc.$MAIN_DOMAIN

4. Verificar PTR:
   dig -x $(curl -s ifconfig.me) +short

5. Teste completo online:
   - https://mxtoolbox.com/SuperTool.aspx
   - https://www.mail-tester.com/
   - https://dkimvalidator.com/

======================================================================
  MONITORAMENTO DMARC
======================================================================

Você receberá relatórios DMARC em: $ADMIN_EMAIL

Ferramentas para analisar relatórios DMARC:
- https://dmarc.postmarkapp.com/
- https://dmarcian.com/
- Parsedmarc (open source): https://github.com/domainaware/parsedmarc

EOF

################################################################################
# INICIAR SERVIÇOS
################################################################################

log_info "Iniciando e habilitando serviços..."

systemctl enable postfix
systemctl enable dovecot
systemctl enable opendkim

systemctl restart postfix
systemctl restart dovecot
systemctl restart opendkim

# Aguardar serviços iniciarem
sleep 3

################################################################################
# VERIFICAÇÕES FINAIS
################################################################################

log_info "Executando verificações finais..."

# Verificar se os serviços estão rodando
if ! systemctl is-active --quiet postfix; then
    log_error "Postfix não está rodando!"
    systemctl status postfix
    exit 1
fi

if ! systemctl is-active --quiet dovecot; then
    log_error "Dovecot não está rodando!"
    systemctl status dovecot
    exit 1
fi

if ! systemctl is-active --quiet opendkim; then
    log_error "OpenDKIM não está rodando!"
    systemctl status opendkim
    exit 1
fi

# Verificar portas
if ! netstat -tuln | grep -q ':587 '; then
    log_warn "Porta 587 (submission) não está em escuta!"
fi

################################################################################
# RESUMO FINAL
################################################################################

clear
echo "========================================================================"
echo "  INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "========================================================================"
echo ""
echo "Informações do Servidor:"
echo "  - Hostname: $HOSTNAME"
echo "  - Domínio: $MAIN_DOMAIN"
echo "  - Porta SMTP (submission): 587"
echo "  - Autenticação: SASL via Dovecot"
echo "  - TLS: Ativo"
echo "  - OpenDKIM: Ativo"
echo ""
echo "Banco de Dados SQLite:"
echo "  - Localização: $DB_DIR/mailserver.db"
echo ""
echo "Certificados SSL:"
echo "  - Certificado: $SSL_CERT"
echo "  - Chave: $SSL_KEY"
echo ""
if [ -n "$RELAYHOST" ]; then
echo "Relayhost Configurado:"
echo "  - Host: $RELAYHOST"
echo "  - Usuário: $RELAYHOST_USER"
echo ""
fi
echo "Scripts de Gerenciamento:"
echo "  - smtp-add-domain.sh <dominio>           - Adicionar novo domínio"
echo "  - smtp-add-user.sh <email> <senha>       - Adicionar usuário"
echo "  - smtp-list-users.sh                      - Listar usuários"
echo "  - smtp-check-config.sh                    - Verificar configuração"
echo ""
echo "Configuração DNS:"
echo "  - Arquivo: /root/CONFIGURACAO_DNS.txt"
echo "  - IMPORTANTE: Configure os registros DNS antes de enviar emails!"
echo ""
echo "Chave DKIM do domínio principal:"
cat "$DKIM_DIR/keys/${MAIN_DOMAIN}.txt"
echo ""
echo "========================================================================"
echo "  PRÓXIMOS PASSOS"
echo "========================================================================"
echo ""
echo "1. Configure os registros DNS (veja /root/CONFIGURACAO_DNS.txt)"
echo "2. Adicione domínios: smtp-add-domain.sh seudominio.com"
echo "3. Adicione usuários: smtp-add-user.sh user@seudominio.com senha123"
echo "4. Teste o envio de email:"
echo "   echo 'Teste' | mail -s 'Assunto' -a 'From: user@$MAIN_DOMAIN' destino@exemplo.com"
echo ""
echo "5. Monitore os logs:"
echo "   tail -f /var/log/mail.log"
echo ""
echo "6. Verifique a configuração:"
echo "   smtp-check-config.sh"
echo ""
echo "========================================================================"

log_info "Instalação finalizada!"
