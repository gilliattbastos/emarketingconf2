#!/bin/bash

################################################################################
# Script de Instalação do Sincronizador MySQL -> SQLite
# Configura o ambiente e agenda sincronização automática
################################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

echo "========================================================================"
echo "  INSTALAÇÃO DO SINCRONIZADOR MySQL -> SQLite"
echo "========================================================================"
echo ""

# Verificar se Python 3 está instalado
if ! command -v python3 &> /dev/null; then
    log_error "Python 3 não está instalado!"
    log_info "Instalando Python 3..."
    apt-get update
    apt-get install -y python3 python3-pip
fi

# Verificar se python3-pip está instalado
if ! command -v python3-pip &> /dev/null; then
    log_error "python3-pip não está instalado!"
    log_info "Instalando python3-pip..."
    apt-get update
    apt-get install -y python3-pip
fi

PYTHON_VERSION=$(python3 --version)
log_info "Python instalado: $PYTHON_VERSION"

# Instalar dependências Python
log_info "Instalando dependências Python..."
pip3 install pymysql tabulate

# Verificar se o script existe
SCRIPT_PATH="/usr/local/bin/mysql-to-sqlite-sync.py"
if [ ! -f "$SCRIPT_PATH" ]; then
    log_info "Copiando script para $SCRIPT_PATH..."
    cp mysql-to-sqlite-sync.py "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
fi

# Criar diretório de configuração
CONFIG_DIR="/etc/postfix/db"
mkdir -p "$CONFIG_DIR"

# Copiar arquivo de configuração se não existir
CONFIG_FILE="$CONFIG_DIR/sync-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    log_info "Criando arquivo de configuração..."
    
    echo ""
    read -p "Digite o host do MySQL [localhost]: " MYSQL_HOST
    MYSQL_HOST=${MYSQL_HOST:-localhost}
    
    read -p "Digite a porta do MySQL [3306]: " MYSQL_PORT
    MYSQL_PORT=${MYSQL_PORT:-3306}
    
    read -p "Digite o usuário do MySQL [root]: " MYSQL_USER
    MYSQL_USER=${MYSQL_USER:-root}
    
    read -sp "Digite a senha do MySQL: " MYSQL_PASSWORD
    echo ""
    
    read -p "Digite o nome do banco MySQL [mailserver]: " MYSQL_DATABASE
    MYSQL_DATABASE=${MYSQL_DATABASE:-mailserver}
    
    read -p "Digite o caminho do SQLite [/etc/postfix/db/mailserver.db]: " SQLITE_PATH
    SQLITE_PATH=${SQLITE_PATH:-/etc/postfix/db/mailserver.db}
    
    cat > "$CONFIG_FILE" << EOF
{
    "mysql": {
        "host": "$MYSQL_HOST",
        "port": $MYSQL_PORT,
        "user": "$MYSQL_USER",
        "password": "$MYSQL_PASSWORD",
        "database": "$MYSQL_DATABASE"
    },
    "sqlite": {
        "path": "$SQLITE_PATH"
    },
    "sync": {
        "interval_minutes": 5,
        "log_file": "/var/log/mysql-sqlite-sync.log"
    }
}
EOF
    
    chmod 600 "$CONFIG_FILE"
    log_info "Arquivo de configuração criado: $CONFIG_FILE"
else
    log_warn "Arquivo de configuração já existe: $CONFIG_FILE"
fi

# Testar conexão
log_info "Testando sincronização..."
if python3 "$SCRIPT_PATH" -c "$CONFIG_FILE"; then
    log_info "Teste de sincronização bem-sucedido!"
else
    log_error "Erro no teste de sincronização. Verifique as configurações."
    exit 1
fi

# Configurar cron
echo ""
log_info "Escolha o método de agendamento:"
echo "  1) Cron (tradicional)"
echo "  2) Systemd Timer (recomendado)"
echo ""
read -p "Opção [2]: " SCHEDULE_METHOD
SCHEDULE_METHOD=${SCHEDULE_METHOD:-2}

if [ "$SCHEDULE_METHOD" = "1" ]; then
    # Configurar via Cron
    read -p "Intervalo de sincronização em minutos [5]: " INTERVAL
    INTERVAL=${INTERVAL:-5}
    
    CRON_LINE="*/$INTERVAL * * * * /usr/bin/python3 $SCRIPT_PATH -c $CONFIG_FILE >> /var/log/mysql-sqlite-sync.log 2>&1"
    
    # Verificar se já existe
    if crontab -l 2>/dev/null | grep -q "mysql-to-sqlite-sync.py"; then
        log_warn "Entrada do cron já existe. Removendo antiga..."
        crontab -l 2>/dev/null | grep -v "mysql-to-sqlite-sync.py" | crontab -
    fi
    
    # Adicionar ao cron
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
    
    log_info "Sincronização automática configurada via Cron (a cada $INTERVAL minutos)"
    
elif [ "$SCHEDULE_METHOD" = "2" ]; then
    # Configurar via Systemd
    read -p "Intervalo de sincronização em minutos [5]: " INTERVAL
    INTERVAL=${INTERVAL:-5}
    
    # Copiar service
    cp mysql-sqlite-sync.service /etc/systemd/system/
    
    # Criar timer customizado com intervalo escolhido
    cat > /etc/systemd/system/mysql-sqlite-sync.timer << EOF
[Unit]
Description=MySQL to SQLite Sync Timer
Requires=mysql-sqlite-sync.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=${INTERVAL}min
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    
    # Recarregar systemd
    systemctl daemon-reload
    
    # Habilitar e iniciar timer
    systemctl enable mysql-sqlite-sync.timer
    systemctl start mysql-sqlite-sync.timer
    
    log_info "Sincronização automática configurada via Systemd Timer (a cada $INTERVAL minutos)"
    log_info "Comandos úteis:"
    log_info "  systemctl status mysql-sqlite-sync.timer    - Ver status do timer"
    log_info "  systemctl status mysql-sqlite-sync.service  - Ver status do serviço"
    log_info "  journalctl -u mysql-sqlite-sync.service -f  - Ver logs"
fi

# Criar script de wrapper para facilitar execução manual
cat > /usr/local/bin/sync-mail-db << 'EOF'
#!/bin/bash
# Wrapper para sincronização manual

python3 /usr/local/bin/mysql-to-sqlite-sync.py -c /etc/postfix/db/sync-config.json "$@"
EOF

chmod +x /usr/local/bin/sync-mail-db

# Criar script para verificar status
if [ -f "check-sync-status.py" ]; then
    cp check-sync-status.py /usr/local/bin/
    chmod +x /usr/local/bin/check-sync-status.py
    
    cat > /usr/local/bin/check-mail-sync << 'EOF'
#!/bin/bash
# Wrapper para verificar status de sincronização

python3 /usr/local/bin/check-sync-status.py "$@"
EOF
    
    chmod +x /usr/local/bin/check-mail-sync
fi

# Criar logrotate
cat > /etc/logrotate.d/mysql-sqlite-sync << 'EOF'
/var/log/mysql-sqlite-sync.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
EOF

echo ""
echo "========================================================================"
echo "  INSTALAÇÃO CONCLUÍDA!"
echo "========================================================================"
echo ""
echo "Configuração:"
echo "  - Script: $SCRIPT_PATH"
echo "  - Config: $CONFIG_FILE"
echo "  - Log: /var/log/mysql-sqlite-sync.log"
echo ""
echo "Comandos disponíveis:"
echo "  sync-mail-db              - Executar sincronização manualmente"
echo "  sync-mail-db --help       - Ver opções disponíveis"
echo "  check-mail-sync           - Verificar status de sincronização"
echo ""
if [ "$SCHEDULE_METHOD" = "2" ]; then
    echo "Gerenciar serviço (Systemd):"
    echo "  systemctl status mysql-sqlite-sync.timer     - Ver status do timer"
    echo "  systemctl stop mysql-sqlite-sync.timer       - Parar sincronização automática"
    echo "  systemctl start mysql-sqlite-sync.timer      - Iniciar sincronização automática"
    echo "  systemctl disable mysql-sqlite-sync.timer    - Desabilitar no boot"
    echo "  journalctl -u mysql-sqlite-sync.service -f   - Ver logs em tempo real"
    echo ""
fi
echo "Visualizar logs:"
echo "  tail -f /var/log/mysql-sqlite-sync.log"
echo ""
echo "Testar conexão MySQL:"
echo "  mysql -h $MYSQL_HOST -u $MYSQL_USER -p $MYSQL_DATABASE"
echo ""
echo "========================================================================"