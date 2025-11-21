#!/bin/bash

################################################################################
# Script de Gerenciamento do Servidor SMTP
# Utilitário para gerenciar usuários, domínios e configurações
################################################################################

DB="/etc/postfix/db/mailserver.db"
DKIM_DIR="/etc/opendkim"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Função para exibir menu
show_menu() {
    clear
    echo "========================================================================"
    echo "  GERENCIADOR DE SERVIDOR SMTP"
    echo "========================================================================"
    echo ""
    echo "  DOMÍNIOS:"
    echo "    1) Adicionar domínio"
    echo "    2) Listar domínios"
    echo "    3) Desabilitar domínio"
    echo "    4) Habilitar domínio"
    echo "    5) Remover domínio"
    echo ""
    echo "  USUÁRIOS:"
    echo "    6) Adicionar usuário"
    echo "    7) Listar usuários"
    echo "    8) Alterar senha de usuário"
    echo "    9) Desabilitar usuário"
    echo "   10) Habilitar usuário"
    echo "   11) Bloquear envio de usuário"
    echo "   12) Desbloquear envio de usuário"
    echo "   13) Remover usuário"
    echo ""
    echo "  ALIAS:"
    echo "   14) Adicionar alias"
    echo "   15) Listar alias"
    echo "   16) Remover alias"
    echo ""
    echo "  SISTEMA:"
    echo "   17) Ver status dos serviços"
    echo "   18) Ver logs em tempo real"
    echo "   19) Ver fila de emails"
    echo "   20) Processar fila de emails"
    echo "   21) Limpar fila de emails"
    echo "   22) Testar configuração"
    echo "   23) Backup do banco de dados"
    echo "   24) Renovar certificado SSL"
    echo ""
    echo "    0) Sair"
    echo ""
    echo "========================================================================"
    echo -n "Escolha uma opção: "
}

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}[ERRO]${NC} Este script deve ser executado como root"
    exit 1
fi

# Verificar se o banco existe
if [ ! -f "$DB" ]; then
    echo -e "${RED}[ERRO]${NC} Banco de dados não encontrado: $DB"
    exit 1
fi

# Função para adicionar domínio
add_domain() {
    echo ""
    echo "=== Adicionar Domínio ==="
    read -p "Digite o domínio (ex: exemplo.com): " DOMAIN
    
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}[ERRO]${NC} Domínio não pode ser vazio"
        return
    fi
    
    # Verificar se já existe
    EXISTS=$(sqlite3 $DB "SELECT COUNT(*) FROM tb_mail_domain WHERE domain='$DOMAIN';")
    if [ "$EXISTS" -gt 0 ]; then
        echo -e "${YELLOW}[AVISO]${NC} Domínio já existe!"
        return
    fi
    
    # Adicionar ao banco
    sqlite3 $DB "INSERT INTO tb_mail_domain (domain, transport, active) VALUES ('$DOMAIN', 'virtual', 1);"
    
    # Gerar chave DKIM
    echo -e "${GREEN}[INFO]${NC} Gerando chave DKIM..."
    opendkim-genkey -b 2048 -d "$DOMAIN" -D "$DKIM_DIR/keys" -s mail -v
    mv "$DKIM_DIR/keys/mail.private" "$DKIM_DIR/keys/${DOMAIN}.private"
    mv "$DKIM_DIR/keys/mail.txt" "$DKIM_DIR/keys/${DOMAIN}.txt"
    
    # Atualizar configurações DKIM
    echo "mail._domainkey.$DOMAIN $DOMAIN:mail:$DKIM_DIR/keys/${DOMAIN}.private" >> $DKIM_DIR/key.table
    echo "*@$DOMAIN mail._domainkey.$DOMAIN" >> $DKIM_DIR/signing.table
    echo "$DOMAIN" >> $DKIM_DIR/trusted.hosts
    
    chown -R opendkim:opendkim "$DKIM_DIR"
    chmod 640 "$DKIM_DIR/keys/${DOMAIN}.private"
    
    echo -e "${GREEN}[SUCESSO]${NC} Domínio $DOMAIN adicionado!"
    echo ""
    echo "Adicione este registro DNS TXT para DKIM:"
    echo "========================================"
    cat "$DKIM_DIR/keys/${DOMAIN}.txt"
    echo "========================================"
    
    systemctl reload opendkim
    systemctl reload postfix
    
    read -p "Pressione ENTER para continuar..."
}

# Função para listar domínios
list_domains() {
    echo ""
    echo "=== Domínios Cadastrados ==="
    sqlite3 -header -column $DB "SELECT cd_domain as ID, domain as Domínio, transport as Transporte, active as Ativo, created as 'Data Criação' FROM tb_mail_domain ORDER BY cd_domain;"
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# Função para desabilitar domínio
disable_domain() {
    echo ""
    echo "=== Desabilitar Domínio ==="
    read -p "Digite o domínio: " DOMAIN
    
    sqlite3 $DB "UPDATE tb_mail_domain SET active=0 WHERE domain='$DOMAIN';"
    echo -e "${GREEN}[SUCESSO]${NC} Domínio $DOMAIN desabilitado!"
    
    systemctl reload postfix
    read -p "Pressione ENTER para continuar..."
}

# Função para habilitar domínio
enable_domain() {
    echo ""
    echo "=== Habilitar Domínio ==="
    read -p "Digite o domínio: " DOMAIN
    
    sqlite3 $DB "UPDATE tb_mail_domain SET active=1 WHERE domain='$DOMAIN';"
    echo -e "${GREEN}[SUCESSO]${NC} Domínio $DOMAIN habilitado!"
    
    systemctl reload postfix
    read -p "Pressione ENTER para continuar..."
}

# Função para remover domínio
remove_domain() {
    echo ""
    echo "=== Remover Domínio ==="
    read -p "Digite o domínio: " DOMAIN
    
    echo -e "${YELLOW}[AVISO]${NC} Isso irá remover o domínio e todos os usuários associados!"
    read -p "Tem certeza? (s/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
        echo "Operação cancelada."
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    # Remover usuários do domínio
    sqlite3 $DB "DELETE FROM tb_mail_mailbox WHERE domain='$DOMAIN';"
    
    # Remover alias do domínio
    sqlite3 $DB "DELETE FROM tb_mail_alias WHERE domain='$DOMAIN';"
    
    # Remover domínio
    sqlite3 $DB "DELETE FROM tb_mail_domain WHERE domain='$DOMAIN';"
    
    echo -e "${GREEN}[SUCESSO]${NC} Domínio $DOMAIN removido!"
    read -p "Pressione ENTER para continuar..."
}

# Função para adicionar usuário
add_user() {
    echo ""
    echo "=== Adicionar Usuário ==="
    read -p "Digite o email completo (ex: user@exemplo.com): " EMAIL
    read -sp "Digite a senha: " PASSWORD
    echo ""
    
    if [ -z "$EMAIL" ] || [ -z "$PASSWORD" ]; then
        echo -e "${RED}[ERRO]${NC} Email e senha não podem ser vazios"
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    DOMAIN=$(echo $EMAIL | cut -d@ -f2)
    
    # Verificar se o domínio existe
    DOMAIN_EXISTS=$(sqlite3 $DB "SELECT COUNT(*) FROM tb_mail_domain WHERE domain='$DOMAIN' AND active=1;")
    
    if [ "$DOMAIN_EXISTS" -eq 0 ]; then
        echo -e "${RED}[ERRO]${NC} Domínio $DOMAIN não existe ou está desabilitado!"
        echo "Adicione o domínio primeiro."
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    # Verificar se usuário já existe
    USER_EXISTS=$(sqlite3 $DB "SELECT COUNT(*) FROM tb_mail_mailbox WHERE username='$EMAIL';")
    if [ "$USER_EXISTS" -gt 0 ]; then
        echo -e "${YELLOW}[AVISO]${NC} Usuário já existe!"
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    # Adicionar usuário
    sqlite3 $DB "INSERT INTO tb_mail_mailbox (username, password, domain, active, active_send) VALUES ('$EMAIL', '$PASSWORD', '$DOMAIN', 1, 1);"
    
    echo -e "${GREEN}[SUCESSO]${NC} Usuário $EMAIL adicionado!"
    read -p "Pressione ENTER para continuar..."
}

# Função para listar usuários
list_users() {
    echo ""
    echo "=== Usuários Cadastrados ==="
    sqlite3 -header -column $DB "SELECT cd_mailbox as ID, username as Email, domain as Domínio, active as Ativo, active_send as 'Envio Ativo' FROM tb_mail_mailbox ORDER BY domain, username;"
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# Função para alterar senha
change_password() {
    echo ""
    echo "=== Alterar Senha de Usuário ==="
    read -p "Digite o email: " EMAIL
    read -sp "Digite a nova senha: " PASSWORD
    echo ""
    
    sqlite3 $DB "UPDATE tb_mail_mailbox SET password='$PASSWORD' WHERE username='$EMAIL';"
    echo -e "${GREEN}[SUCESSO]${NC} Senha alterada para $EMAIL!"
    read -p "Pressione ENTER para continuar..."
}

# Função para desabilitar usuário
disable_user() {
    echo ""
    echo "=== Desabilitar Usuário ==="
    read -p "Digite o email: " EMAIL
    
    sqlite3 $DB "UPDATE tb_mail_mailbox SET active=0 WHERE username='$EMAIL';"
    echo -e "${GREEN}[SUCESSO]${NC} Usuário $EMAIL desabilitado!"
    read -p "Pressione ENTER para continuar..."
}

# Função para habilitar usuário
enable_user() {
    echo ""
    echo "=== Habilitar Usuário ==="
    read -p "Digite o email: " EMAIL
    
    sqlite3 $DB "UPDATE tb_mail_mailbox SET active=1 WHERE username='$EMAIL';"
    echo -e "${GREEN}[SUCESSO]${NC} Usuário $EMAIL habilitado!"
    read -p "Pressione ENTER para continuar..."
}

# Função para bloquear envio
block_sending() {
    echo ""
    echo "=== Bloquear Envio de Usuário ==="
    read -p "Digite o email: " EMAIL
    
    sqlite3 $DB "UPDATE tb_mail_mailbox SET active_send=0 WHERE username='$EMAIL';"
    echo -e "${GREEN}[SUCESSO]${NC} Envio bloqueado para $EMAIL!"
    read -p "Pressione ENTER para continuar..."
}

# Função para desbloquear envio
unblock_sending() {
    echo ""
    echo "=== Desbloquear Envio de Usuário ==="
    read -p "Digite o email: " EMAIL
    
    sqlite3 $DB "UPDATE tb_mail_mailbox SET active_send=1 WHERE username='$EMAIL';"
    echo -e "${GREEN}[SUCESSO]${NC} Envio desbloqueado para $EMAIL!"
    read -p "Pressione ENTER para continuar..."
}

# Função para remover usuário
remove_user() {
    echo ""
    echo "=== Remover Usuário ==="
    read -p "Digite o email: " EMAIL
    
    read -p "Tem certeza que deseja remover $EMAIL? (s/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
        echo "Operação cancelada."
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    sqlite3 $DB "DELETE FROM tb_mail_mailbox WHERE username='$EMAIL';"
    echo -e "${GREEN}[SUCESSO]${NC} Usuário $EMAIL removido!"
    read -p "Pressione ENTER para continuar..."
}

# Função para adicionar alias
add_alias() {
    echo ""
    echo "=== Adicionar Alias ==="
    read -p "Digite o endereço do alias (ex: vendas@exemplo.com): " ADDRESS
    read -p "Digite o(s) destino(s) separados por vírgula (ex: joao@exemplo.com,maria@exemplo.com): " GOTO
    
    DOMAIN=$(echo $ADDRESS | cut -d@ -f2)
    
    sqlite3 $DB "INSERT INTO tb_mail_alias (address, goto, domain, active) VALUES ('$ADDRESS', '$GOTO', '$DOMAIN', 1);"
    
    echo -e "${GREEN}[SUCESSO]${NC} Alias $ADDRESS -> $GOTO adicionado!"
    systemctl reload postfix
    read -p "Pressione ENTER para continuar..."
}

# Função para listar alias
list_aliases() {
    echo ""
    echo "=== Alias Cadastrados ==="
    sqlite3 -header -column $DB "SELECT cd_alias as ID, address as Alias, goto as Destino, domain as Domínio, active as Ativo FROM tb_mail_alias ORDER BY domain, address;"
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# Função para remover alias
remove_alias() {
    echo ""
    echo "=== Remover Alias ==="
    read -p "Digite o endereço do alias: " ADDRESS
    
    sqlite3 $DB "DELETE FROM tb_mail_alias WHERE address='$ADDRESS';"
    echo -e "${GREEN}[SUCESSO]${NC} Alias $ADDRESS removido!"
    systemctl reload postfix
    read -p "Pressione ENTER para continuar..."
}

# Função para ver status
show_status() {
    echo ""
    echo "=== Status dos Serviços ==="
    echo ""
    echo "Postfix:"
    systemctl status postfix --no-pager | head -3
    echo ""
    echo "Dovecot:"
    systemctl status dovecot --no-pager | head -3
    echo ""
    echo "OpenDKIM:"
    systemctl status opendkim --no-pager | head -3
    echo ""
    echo "=== Portas em Escuta ==="
    netstat -tuln | grep -E ':(25|587|8891) '
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# Função para ver logs
show_logs() {
    echo ""
    echo "=== Logs em Tempo Real (Ctrl+C para sair) ==="
    tail -f /var/log/mail.log
}

# Função para ver fila
show_queue() {
    echo ""
    echo "=== Fila de Emails ==="
    postqueue -p
    echo ""
    read -p "Pressione ENTER para continuar..."
}

# Função para processar fila
process_queue() {
    echo ""
    echo "=== Processando Fila ==="
    postqueue -f
    echo -e "${GREEN}[SUCESSO]${NC} Fila processada!"
    read -p "Pressione ENTER para continuar..."
}

# Função para limpar fila
clear_queue() {
    echo ""
    echo "=== Limpar Fila ==="
    echo -e "${YELLOW}[AVISO]${NC} Isso irá remover TODOS os emails da fila!"
    read -p "Tem certeza? (s/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
        echo "Operação cancelada."
        read -p "Pressione ENTER para continuar..."
        return
    fi
    
    postsuper -d ALL
    echo -e "${GREEN}[SUCESSO]${NC} Fila limpa!"
    read -p "Pressione ENTER para continuar..."
}

# Função para testar configuração
test_config() {
    echo ""
    echo "=== Teste de Configuração ==="
    echo ""
    
    echo "Postfix:"
    postfix check
    echo ""
    
    echo "Dovecot:"
    doveconf -n | head -20
    echo ""
    
    echo "OpenDKIM:"
    opendkim-testkey -d $(sqlite3 $DB "SELECT domain FROM tb_mail_domain LIMIT 1;") -s mail -vvv
    echo ""
    
    read -p "Pressione ENTER para continuar..."
}

# Função para backup
backup_db() {
    echo ""
    echo "=== Backup do Banco de Dados ==="
    BACKUP_FILE="/root/backup-mail-$(date +%Y%m%d-%H%M%S).sql"
    sqlite3 $DB .dump > $BACKUP_FILE
    echo -e "${GREEN}[SUCESSO]${NC} Backup criado em: $BACKUP_FILE"
    read -p "Pressione ENTER para continuar..."
}

# Função para renovar SSL
renew_ssl() {
    echo ""
    echo "=== Renovar Certificado SSL ==="
    read -p "Digite o hostname: " HOSTNAME
    read -p "Digite o email: " EMAIL
    
    lego --email="$EMAIL" \
         --domains="$HOSTNAME" \
         --path="/etc/lego" \
         renew
    
    systemctl reload postfix
    echo -e "${GREEN}[SUCESSO]${NC} Certificado renovado!"
    read -p "Pressione ENTER para continuar..."
}

# Loop principal
while true; do
    show_menu
    read option
    
    case $option in
        1) add_domain ;;
        2) list_domains ;;
        3) disable_domain ;;
        4) enable_domain ;;
        5) remove_domain ;;
        6) add_user ;;
        7) list_users ;;
        8) change_password ;;
        9) disable_user ;;
        10) enable_user ;;
        11) block_sending ;;
        12) unblock_sending ;;
        13) remove_user ;;
        14) add_alias ;;
        15) list_aliases ;;
        16) remove_alias ;;
        17) show_status ;;
        18) show_logs ;;
        19) show_queue ;;
        20) process_queue ;;
        21) clear_queue ;;
        22) test_config ;;
        23) backup_db ;;
        24) renew_ssl ;;
        0) exit 0 ;;
        *) 
            echo -e "${RED}[ERRO]${NC} Opção inválida!"
            sleep 2
            ;;
    esac
done
