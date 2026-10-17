#!/bin/bash
# ==============================================================================
# INSTALLER ODOO + OCA SYNC (Bare-Metal Ubuntu/Debian)
# Ottimizzato con Auto-Tuning, Backup, Logrotate e Guida NPM
# ==============================================================================

set -e
export DEBIAN_FRONTEND=noninteractive

# ==============================================================================
# VARIABILI DI CONFIGURAZIONE GLOBALE
# ==============================================================================
OE_USER="odoo"
OE_HOME="/opt/$OE_USER"
OE_HOME_EXT="$OE_HOME/odoo-server"
OCA_REPOS_DIR="$OE_HOME/oca_repos"
CUSTOM_ADDONS_DIR="$OE_HOME/custom_addons"
VENV_DIR="$OE_HOME/venv"
PIP_CMD="$VENV_DIR/bin/pip"
PYTHON_CMD="$VENV_DIR/bin/python3"
OE_CONFIG="/etc/odoo.conf"
BACKUP_SCRIPT="/opt/odoo_backup.sh"
NPM_GUIDE="/opt/guida_npm_odoo.txt"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Assicura la presenza di sudo e aggiorna il sistema
apt-get update -qq
apt-get install -y sudo curl wget
sudo apt update && sudo apt upgrade -y

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Errore: Questo script deve essere eseguito come root (sudo).${NC}"
    exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}    Installer Odoo OCA/l10n-italy e OCA (Ubuntu/Debian Bare-Metal)${NC}"
echo -e "${BLUE}======================================================================${NC}"

# ------------------------------------------------------------------------------
# SELETTORE VERSIONE ODOO
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Seleziona la versione di Odoo da installare:${NC}"
PS3="Inserisci il numero corrispondente (1-4): "
options=("18.0" "17.0" "16.0" "Esci")
select opt in "${options[@]}"; do
    case $opt in
        "18.0"|"17.0"|"16.0")
            OE_VERSION=$opt
            break
            ;;
        "Esci")
            echo "Uscita..."
            exit 0
            ;;
        *) echo -e "${RED}Opzione non valida. Riprova.${NC}" ;;
    esac
done

# ------------------------------------------------------------------------------
# SELETTORE MODULI OCA & LOCALIZZAZIONE
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Seleziona la modalità di download per i moduli OCA:${NC}"
PS3="Inserisci il numero corrispondente (1-2): "
oca_options=("Solo repository Popolari (Consigliato)" "Tutti i repository (Full - Lento, multi-GB)")
select opt_oca in "${oca_options[@]}"; do
    case $REPLY in
        1) OCA_MODE="popular"; break ;;
        2) OCA_MODE="full"; break ;;
        *) echo -e "${RED}Opzione non valida.${NC}" ;;
    esac
done

echo -e "\n${BLUE}--- Localizzazione OCA ---${NC}"
echo -e "${GREEN}Di default, il modulo di localizzazione italiana (OCA/l10n-italy) verrà scaricato.${NC}"
read -p "Vuoi aggiungere un'altra localizzazione? (Inserisci il nome, es. l10n-spain, oppure premi INVIO per nessuna): " EXTRA_L10N

# ==============================================================================
# FUNZIONE DI AUTO-TUNING
# ==============================================================================
calculate_tuning() {
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    TOTAL_CPUs=$(nproc)
    PG_SHARED_BUFFERS=$((TOTAL_RAM_MB / 4))
    [ $PG_SHARED_BUFFERS -lt 128 ] && PG_SHARED_BUFFERS=128
    PG_EFFECTIVE_CACHE=$(( (TOTAL_RAM_MB * 3) / 4 ))
    ODOO_WORKERS=$(( (TOTAL_CPUs * 2) + 1 ))
    LIMIT_MEMORY_SOFT=2147483648  # 2 GB
    LIMIT_MEMORY_HARD=2684354560  # 2.5 GB
}
calculate_tuning

# ==============================================================================
# 1. INSTALLAZIONE DIPENDENZE E POSTGRESQL
# ==============================================================================
echo -e "\n${BLUE}>>> Aggiornamento sistema e verifica pacchetti base...${NC}"
apt-get update -qq

PACKAGES=(
    "locales" "git" "curl" "jq" "wget" "mc" "btop" "nano"
    "python3-full" "python3-dev" "python3-venv" "build-essential"
    "libpq-dev" "libxml2-dev" "libxslt1-dev" "libldap2-dev" "libsasl2-dev" "libssl-dev" "libffi-dev"
    "postgresql" "postgresql-client" "nodejs" "npm"
    "xfonts-75dpi" "xfonts-base" "fontconfig" "libxrender1" "libxext6"
)

MISSING_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l | grep -q -w "^ii  $pkg"; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --no-install-recommends "${MISSING_PACKAGES[@]}"
fi

echo -e "\n${BLUE}>>> Configurazione del Locale di sistema (en_US.UTF-8)...${NC}"
locale-gen en_US.UTF-8 >/dev/null
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

if ! command -v rtlcss > /dev/null; then npm install -g rtlcss >/dev/null 2>&1; fi
if ! command -v wkhtmltopdf > /dev/null; then
    wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
    apt-get install -y ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb >/dev/null
    rm wkhtmltox_0.12.6.1-2.jammy_amd64.deb
    ln -sf /usr/local/bin/wkhtmltopdf /usr/bin/wkhtmltopdf 2>/dev/null
    ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage 2>/dev/null
fi

# ==============================================================================
# 2. UTENTI E TUNING POSTGRESQL
# ==============================================================================
if ! id -u "$OE_USER" > /dev/null 2>&1; then 
    useradd -m -U -r -d "$OE_HOME" -s /bin/bash "$OE_USER"
fi

mkdir -p "$CUSTOM_ADDONS_DIR" "$OCA_REPOS_DIR"
chown -R "$OE_USER:$OE_USER" "$OE_HOME"

PG_VERSION=$(pg_lsclusters -h | awk '{print $1}')
if [ -n "$PG_VERSION" ]; then
    PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    if [ -f "$PG_CONF_FILE" ]; then
        sed -i "s/^#*shared_buffers =.*/shared_buffers = ${PG_SHARED_BUFFERS}MB/" "$PG_CONF_FILE"
        sed -i "s/^#*effective_cache_size =.*/effective_cache_size = ${PG_EFFECTIVE_CACHE}MB/" "$PG_CONF_FILE"
        systemctl restart postgresql
    fi
fi
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$OE_USER'" | grep -q 1 || sudo -u postgres createuser -s "$OE_USER"

# ==============================================================================
# 3. CLONE ODOO E VENV
# ==============================================================================
echo -e "\n${BLUE}>>> Configurazione Odoo $OE_VERSION e Virtual Environment...${NC}"

if [ ! -d "$OE_HOME_EXT" ]; then
    sudo -u "$OE_USER" git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/odoo "$OE_HOME_EXT"
else
    cd "$OE_HOME_EXT" && sudo -u "$OE_USER" git pull origin "$OE_VERSION"
fi

if [ ! -d "$VENV_DIR" ]; then 
    sudo -u "$OE_USER" python3 -m venv "$VENV_DIR"
fi
sudo -u "$OE_USER" "$PIP_CMD" install --upgrade pip wheel setuptools >/dev/null
sudo -u "$OE_USER" "$PIP_CMD" install -r "$OE_HOME_EXT/requirements.txt" >/dev/null

# ==============================================================================
# 4. DOWNLOAD E SINCRONIZZAZIONE MODULI OCA
# ==============================================================================
echo -e "\n${BLUE}>>> Sincronizzazione repository OCA...${NC}"
OCA_REPOS_LIST=()

if [ "$OCA_MODE" = "full" ]; then
    PAGE=1
    while :; do
        RESPONSE=$(curl -s "https://api.github.com/orgs/OCA/repos?per_page=100&page=${PAGE}")
        if echo "$RESPONSE" | jq -e 'has("message")' > /dev/null; then break; fi
        CURRENT_REPOS=$(echo "$RESPONSE" | jq -r '.[].name' 2>/dev/null)
        [ -z "$CURRENT_REPOS" ] && break
        OCA_REPOS_LIST+=($CURRENT_REPOS)
        ((PAGE++))
    done
else
    OCA_REPOS_LIST=("web" "server-tools" "server-ux" "reporting-engine" "partner-contact" "account-financial-reporting" "social" "mis-builder")
fi

# Aggiunge localizzazione italiana e altre richieste
[[ ! " ${OCA_REPOS_LIST[*]} " =~ " l10n-italy " ]] && OCA_REPOS_LIST+=("l10n-italy")
if [ -n "$EXTRA_L10N" ]; then
    [[ ! " ${OCA_REPOS_LIST[*]} " =~ " $EXTRA_L10N " ]] && OCA_REPOS_LIST+=("$EXTRA_L10N")
fi

for REPO_NAME in "${OCA_REPOS_LIST[@]}"; do
    TARGET_DIR="$OCA_REPOS_DIR/$REPO_NAME"
    REPO_URL="https://github.com/OCA/${REPO_NAME}.git"

    BRANCH_EXISTS=$(git ls-remote --heads "$REPO_URL" "$OE_VERSION" | wc -l)
    if [ "$BRANCH_EXISTS" -eq 0 ]; then continue; fi
    
    echo -e "Elaborazione OCA: ${GREEN}$REPO_NAME${NC}"
    if [ -d "$TARGET_DIR" ]; then
        cd "$TARGET_DIR" || continue
        sudo -u "$OE_USER" git checkout "$OE_VERSION" >/dev/null 2>&1
        sudo -u "$OE_USER" git pull origin "$OE_VERSION" >/dev/null 2>&1
    else
        sudo -u "$OE_USER" git clone -b "$OE_VERSION" --single-branch "$REPO_URL" "$TARGET_DIR" >/dev/null 2>&1
    fi

    for manifest in "$TARGET_DIR"/*/__manifest__.py; do
        if [ -f "$manifest" ]; then
            MODULE_DIR=$(dirname "$manifest")
            sudo -u "$OE_USER" ln -sfn "$MODULE_DIR" "$CUSTOM_ADDONS_DIR/$(basename "$MODULE_DIR")"
        fi
    done

    if [ -f "$TARGET_DIR/requirements.txt" ]; then
        sudo -u "$OE_USER" "$PIP_CMD" install -r "$TARGET_DIR/requirements.txt" >/dev/null 2>&1
    fi
done

# ==============================================================================
# 5. CONFIGURAZIONE, ODOO SYSTEMD, LOGROTATE E BACKUP
# ==============================================================================
echo -e "\n${BLUE}>>> Generazione file di configurazione, Logrotate e Backup Script...${NC}"
mkdir -p /var/log/odoo
chown "$OE_USER:$OE_USER" /var/log/odoo

cat <<EOF > "$OE_CONFIG"
[options]
admin_passwd = admin_password_cambiami
db_host = False
db_port = False
db_user = $OE_USER
db_password = False
addons_path = $OE_HOME_EXT/addons,$CUSTOM_ADDONS_DIR
logfile = /var/log/odoo/odoo.log
xmlrpc_port = 8069
workers = $ODOO_WORKERS
limit_memory_soft = $LIMIT_MEMORY_SOFT
limit_memory_hard = $LIMIT_MEMORY_HARD
limit_time_cpu = 600
limit_time_real = 1200
proxy_mode = True
EOF
chown "$OE_USER:$OE_USER" "$OE_CONFIG"
chmod 640 "$OE_CONFIG"

# --- LOGROTATE ---
cat <<EOF > /etc/logrotate.d/odoo
/var/log/odoo/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 "$OE_USER" "$OE_USER"
}
EOF

# --- BACKUP SCRIPT ---
cat <<EOF > "$BACKUP_SCRIPT"
#!/bin/bash
# Script di backup per Odoo (Database e Filestore)
BACKUP_DIR="/opt/odoo_backups"
DATE=\$(date +"%Y%m%d_%H%M%S")
FILESTORE_DIR="$OE_HOME/.local/share/Odoo/filestore"

mkdir -p "\$BACKUP_DIR"
echo "Avvio Backup Odoo: \$DATE"

DBS=\$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datowner = (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER');")

for DB in \$DBS; do
    echo "Backup DB: \$DB..."
    sudo -u postgres pg_dump "\$DB" | gzip > "\$BACKUP_DIR/db_\${DB}_\${DATE}.sql.gz"
done

if [ -d "\$FILESTORE_DIR" ]; then
    echo "Backup Filestore..."
    tar -czf "\$BACKUP_DIR/filestore_\${DATE}.tar.gz" -C "\$FILESTORE_DIR" .
fi

find "\$BACKUP_DIR" -type f -name "*.gz" -mtime +7 -exec rm {} \;
echo "Backup completato."
EOF
chmod +x "$BACKUP_SCRIPT"

# --- SERVIZIO SYSTEMD ---
cat <<EOF > /etc/systemd/system/odoo.service
[Unit]
Description=Odoo Server
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=odoo
PermissionsStartOnly=true
User=$OE_USER
Group=$OE_USER
Environment="LANG=en_US.UTF-8"
Environment="LC_ALL=en_US.UTF-8"
ExecStart=$PYTHON_CMD $OE_HOME_EXT/odoo-bin -c $OE_CONFIG
KillMode=mixed
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable odoo
systemctl start odoo

# ==============================================================================
# 6. GUIDA NGINX PROXY MANAGER (NPM)
# ==============================================================================
cat << 'EOF' > "$NPM_GUIDE"
========================================================================
GUIDA CONFIGURAZIONE NGINX PROXY MANAGER (NPM) CON ODOO
========================================================================
Poiché Odoo è configurato con "proxy_mode = True", è ottimizzato per 
lavorare dietro un Reverse Proxy. 

Accedi alla UI di Nginx Proxy Manager e crea un nuovo "Proxy Host":

--- SCHEDA: DETAILS ---
1. Domain Names: il.tuo.dominio.it
2. Scheme: http
3. Forward Hostname / IP: <IP LOCALE DEL SERVER ODOO>
4. Forward Port: 8069
5. Cache Assets: ABILITATO
6. Block Common Exploits: ABILITATO
7. Websockets Support: ABILITATO (Fondamentale)

--- SCHEDA: CUSTOM LOCATIONS ---
Per garantire il funzionamento del Longpolling/Websockets (notifiche live):
- Clicca su "Add location"
- Location: /websocket/
- Scheme: http
- Forward Hostname / IP: <IP LOCALE DEL SERVER ODOO>
- Forward Port: 8072

Clicca sull'ingranaggio (Advanced) in questa location:
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "Upgrade";
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;

--- SCHEDA: ADVANCED (Globale) ---
Inserisci questo nel campo "Custom Nginx Configuration":
client_max_body_size 200m;
proxy_read_timeout 720s;
proxy_connect_timeout 720s;
proxy_send_timeout 720s;
========================================================================
EOF

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}Installazione Completata con Successo!${NC}"
echo -e "Odoo è accessibile sulla porta 8069."
echo -e "La guida per Nginx Proxy Manager è stata salvata in: $NPM_GUIDE"
cat "$NPM_GUIDE"
echo -e "${GREEN}======================================================================${NC}"
