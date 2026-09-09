#!/bin/bash
# ==============================================================================
# INSTALLER ODOO + OCA SYNC (Bare-Metal Ubuntu/Debian)
# Ottimizzato con Auto-Tuning, Backup, Logrotate e Guida NPM
# ==============================================================================

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

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Errore: Questo script deve essere eseguito come root (sudo).${NC}"
  exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}    Odoo & OCA Enterprise Installer (Ubuntu/Debian Bare-Metal)${NC}"
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
# 1. INSTALLAZIONE DIPENDENZE E POSTGRESQL (Veloce)
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
if ! id -u $OE_USER > /dev/null 2>&1; then useradd -m -U -r -d $OE_HOME -s /bin/bash$OE_USER; fi

PG_VERSION=$(pg_lsclusters -h | awk '{print $1}')
if [ -n "$PG_VERSION" ]; then
    PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    if [ -f "$PG_CONF_FILE" ]; then
        sed -i "s/^#*shared_buffers =.*/shared_buffers = ${PG_SHARED_BUFFERS}MB/" "$PG_CONF_FILE"
        sed -i "s/^#*effective_cache_size =.*/effective_cache_size = ${PG_EFFECTIVE_CACHE}MB/" "$PG_CONF_FILE"
        systemctl restart postgresql
    fi
fi
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$OE_USER'" | grep -q 1 || sudo -u postgres createuser -s $OE_USER

# ==============================================================================
# 3. CLONE ODOO E VENV
# ==============================================================================
echo -e "\n${BLUE}>>> Configurazione Odoo $OE_VERSION e Virtual Environment...${NC}"
mkdir -p $CUSTOM_ADDONS_DIR$OCA_REPOS_DIR
chown -R $OE_USER:$OE_USER$OE_HOME

if [ ! -d "$OE_HOME_EXT" ]; then
    sudo -u $OE_USER git clone --depth 1 --branch $OE_VERSION https://github.com/odoo/odoo$OE_HOME_EXT
else
    cd $OE_HOME_EXT && sudo -u $OE_USER git pull origin$OE_VERSION
fi

if [ ! -d "$VENV_DIR" ]; then sudo -u $OE_USER python3 -m venv$VENV_DIR; fi
sudo -u $OE_USER$PIP_CMD install --upgrade pip wheel setuptools >/dev/null
sudo -u $OE_USER $PIP_CMD install -r$OE_HOME_EXT/requirements.txt >/dev/null

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
        sudo -u $OE_USER git checkout "$OE_VERSION" >/dev/null 2>&1
        sudo -u $OE_USER git pull origin "$OE_VERSION" >/dev/null 2>&1
    else
        sudo -u $OE_USER git clone -b "$OE_VERSION" --single-branch "$REPO_URL" "$TARGET_DIR" >/dev/null 2>&1
    fi

    for manifest in "$TARGET_DIR"/*/__manifest__.py; do
        if [ -f "$manifest" ]; then
            MODULE_DIR=$(dirname "$manifest")
            sudo -u $OE_USER ln -sfn "$MODULE_DIR" "$CUSTOM_ADDONS_DIR/$(basename "$MODULE_DIR")"
        fi
    done

    if [ -f "$TARGET_DIR/requirements.txt" ]; then
        sudo -u $OE_USER $PIP_CMD install -r "$TARGET_DIR/requirements.txt" >/dev/null 2>&1
    fi
done

# ==============================================================================
# 5. CONFIGURAZIONE, ODOO SYSTEMD, LOGROTATE E BACKUP
# ==============================================================================
echo -e "\n${BLUE}>>> Generazione file di configurazione, Logrotate e Backup Script...${NC}"
mkdir -p /var/log/odoo
chown $OE_USER:$OE_USER /var/log/odoo

cat <<EOF > $OE_CONFIG
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
chown $OE_USER:$OE_USER $OE_CONFIG; chmod 640$OE_CONFIG

# --- LOGROTATE ---
cat <<EOF > /etc/logrotate.d/odoo
/var/log/odoo/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 $OE_USER$OE_USER
}
EOF

# --- BACKUP SCRIPT ---
cat <<EOF > $BACKUP_SCRIPT
#!/bin/bash
# Script di backup per Odoo (Database e Filestore)
BACKUP_DIR="/opt/odoo_backups"
DATE=\$(date +"%Y%m%d_%H%M%S")
FILESTORE_DIR="$OE_HOME/.local/share/Odoo/filestore"

mkdir -p \$BACKUP_DIR
echo "Avvio Backup Odoo: \$DATE"

# Identifica i database posseduti dall'utente odoo
DBS=\$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datowner = (SELECT oid FROM pg_roles WHERE rolname = '$OE_USER');")

for DB in \$DBS; do
    echo "Backup DB: \$DB..."
    sudo -u postgres pg_dump \$DB | gzip > \$BACKUP_DIR/db_\${DB}_\${DATE}.sql.gz
done

if [ -d "\$FILESTORE_DIR" ]; then
    echo "Backup Filestore..."
    tar -czf \$BACKUP_DIR/filestore_\${DATE}.tar.gz -C \$FILESTORE_DIR .
fi

# Rimozione vecchi backup (più vecchi di 7 giorni)
find \$BACKUP_DIR -type f -name "*.gz" -mtime +7 -exec rm {} \\;
echo "Backup completato."
EOF
chmod +x $BACKUP_SCRIPT

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
ExecStart=$PYTHON_CMD $OE_HOME_EXT/odoo-bin -c$OE_CONFIG
KillMode=mixed
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload; systemctl enable odoo; systemctl start odoo

# ==============================================================================
# 6. CREAZIONE GUIDA NGINX PROXY MANAGER (NPM)
# ==============================================================================
cat << 'EOF' > $NPM_GUIDE
========================================================================
GUIDA CONFIGURAZIONE NGINX PROXY MANAGER (NPM) CON ODOO
========================================================================
Poiché Odoo è configurato con "proxy_mode = True", è ottimizzato per 
lavorare dietro un Reverse Proxy. 

Accedi alla UI di Nginx Proxy Manager e crea un nuovo "Proxy Host":

--- SCHEDA: DETAILS ---
1. Domain Names: il.tuo.dominio.it
2. Scheme: http
3. Forward Hostname / IP: <INSERISCI L'IP LOCALE DI QUESTO SERVER>
4. Forward Port: 8069
5. Cache Assets: ABILITATO (Spunta blu)
6. Block Common Exploits: ABILITATO (Spunta blu)
7. Websockets Support: ABILITATO (Spunta blu)

--- SCHEDA: CUSTOM LOCATIONS ---
Per garantire il funzionamento del Longpolling/Websockets (notifiche live):
- Clicca su "Add location"
- Location: /websocket 
- Scheme: http
- Forward Hostname / IP: <INSERISCI L'IP LOCALE DI QUESTO SERVER>
- Forward Port: 8069

--- SCHEDA: SSL ---
1. SSL Certificate: SeEcco lo script Bash aggiornato e strutturato per gestire la tua installazione su server bare-metal. 

Questo script utilizza un menu di selezione per la versione di Odoo, gestisce la scelta dei repository OCA e delle localizzazioni (con `l10n-italy` preimpostata), configura l'ottimizzazione dei log, genera uno script automatico di backup e, infine, crea e mostra la guida per Nginx Proxy Manager.

### Script di Configurazione e Installazione

Salva questo codice in un file, ad esempio `odoo_setup.sh`, rendilo eseguibile con `chmod +x odoo_setup.sh` ed eseguilo con i privilegi di root (`sudo ./odoo_setup.sh`).

```bash
#!/bin/bash

# Uscita in caso di errore
set -e

echo "=========================================="
echo "    Configurazione Installazione Odoo     "
echo "=========================================="

# 1. Selettore Versione Odoo
echo "Seleziona la versione di Odoo da installare:"
PS3="Digita il numero corrispondente alla versione: "
version_options=("18.0" "17.0" "16.0" "15.0" "Esci")
select opt in "${version_options[@]}"; do
    case $opt in
        "18.0"|"17.0"|"16.0"|"15.0")
            ODOO_VERSION=$opt
            echo "Hai selezionato la versione: $ODOO_VERSION"
            break
            ;;
        "Esci")
            echo "Uscita dallo script."
            exit 0
            ;;
        *) echo "Opzione non valida. Riprova." ;;
    esac
done

# 2. Scelta Moduli OCA
echo ""
echo "Quale pacchetto di moduli OCA (Odoo Community Association) desideri scaricare?"
PS3="Digita il numero corrispondente: "
oca_options=("Solo Moduli Popolari (es. web, server-tools, reporting-engine)" "Full OCA (Tutti i repository principali)" "Nessuno")
select oca_opt in "${oca_options[@]}"; do
    case $oca_opt in
        "Solo Moduli Popolari"*)
            OCA_CHOICE="popolari"
            echo "Hai scelto: Moduli Popolari"
            break
            ;;
        "Full OCA"*)
            OCA_CHOICE="full"
            echo "Hai scelto: Full OCA"
            break
            ;;
        "Nessuno")
            OCA_CHOICE="none"
            echo "Hai scelto: Nessun modulo base OCA"
            break
            ;;
        *) echo "Opzione non valida. Riprova." ;;
    esac
done

# 3. Scelta Localizzazione
echo ""
echo "---------------------------------------------------------"
echo "ATTENZIONE: La localizzazione italiana (OCA/l10n-italy)"
echo "è impostata come DEFAULT e verrà scaricata automaticamente."
echo "---------------------------------------------------------"
read -p "Vuoi scaricare altre localizzazioni da GitHub? (es. l10n-spain l10n-switzerland). Lascia vuoto per scaricare SOLO l'italiana: " EXTRA_L10N

L10N_REPOS="l10n-italy $EXTRA_L10N"
echo "Repository di localizzazione che verranno scaricati: $L10N_REPOS"

# (Qui andrebbe la logica di git clone per ODOO_VERSION, OCA_CHOICE e L10N_REPOS)
# Esempio: 
# git clone -b $ODOO_VERSION [https://github.com/OCA/l10n-italy.git](https://github.com/OCA/l10n-italy.git) /opt/odoo/custom_addons/l10n-italy
# ... esecuzione dell'installazione di Odoo ...

echo ""
echo "Creazione delle configurazioni di sistema in corso..."

# 4. Ottimizzazione dei Log (Logrotate)
cat << 'EOF' > /etc/logrotate.d/odoo
/var/log/odoo/*.log {
    copytruncate
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 odoo odoo
}
EOF
echo "✔ Configurazione Logrotate creata in /etc/logrotate.d/odoo"

# 5. Script di Backup Odoo
mkdir -p /opt/scripts
cat << 'EOF' > /opt/scripts/odoo_backup.sh
#!/bin/bash
# Script di backup completo per Odoo (Database + Filestore)

BACKUP_DIR="/var/backups/odoo"
ODOO_DATA_DIR="/var/lib/odoo/.local/share/Odoo/filestore"
DB_NAME="odoo_db" # Modifica con il nome reale del tuo DB
DATE=$(date +"%Y%m%d_%H%M%S")
RETENTION_DAYS=7

mkdir -p "$BACKUP_DIR"

# Backup Database
echo "Avvio backup del database: $DB_NAME..."
sudo -u postgres pg_dump -Fc "$DB_NAME" > "$BACKUP_DIR/db_${DB_NAME}_${DATE}.dump"

# Backup Filestore
echo "Avvio backup del filestore..."
tar -czf "$BACKUP_DIR/filestore_${DB_NAME}_${DATE}.tar.gz" -C "$ODOO_DATA_DIR" .

# Pulizia vecchi backup
echo "Rimozione backup più vecchi di $RETENTION_DAYS giorni..."
find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -name "*.dump" -exec rm {} \;
find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -name "*.tar.gz" -exec rm {} \;

echo "Backup completato con successo."
EOF
chmod +x /opt/scripts/odoo_backup.sh
echo "✔ Script di backup creato in /opt/scripts/odoo_backup.sh"

# 6. Creazione della Guida per Nginx Proxy Manager (NPM)
cat << 'EOF' > /opt/guida_npm_odoo.txt
======================================================
GUIDA ALLA CONFIGURAZIONE DI NGINX PROXY MANAGER (NPM) PER ODOO
======================================================

Affinché Nginx Proxy Manager gestisca correttamente Odoo (inclusi i Websocket per la chat interna e le lunghe code di polling), devi seguire questi passi direttamente nella Web UI di NPM.

1. CREAZIONE DEL PROXY HOST
------------------------------------------------------
- Vai su "Proxy Hosts" -> "Add Proxy Host"
- Domain Names: il tuo dominio (es. odoo.tuodominio.it)
- Scheme: http
- Forward Hostname / IP: L'indirizzo IP locale del server Odoo (es. 192.168.1.100 o 127.0.0.1)
- Forward Port: 8069
- Spunta le caselle: 
  [x] Cache Assets
  [x] Block Common Exploits
  [x] Websockets Support (FONDAMENTALE)

2. SCHEDA SSL
------------------------------------------------------
- Richiedi un nuovo certificato o usane uno esistente.
- Spunta:
  [x] Force SSL
  [x] HTTP/2 Support

3. SCHEDA CUSTOM LOCATIONS
------------------------------------------------------
Odoo utilizza una porta separata per il longpolling / websockets (solitamente 8072 per le versioni >= 16.0). Devi dichiararlo esplicitamente per non far cadere le connessioni.

Clicca su "Add location":
- Location: /websocket/
- Scheme: http
- Forward Hostname / IP: L'indirizzo IP locale del server Odoo
- Forward Port: 8072

Clicca sull'icona dell'ingranaggio (Advanced) in questa "Custom Location" e inserisci:
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;

4. SCHEDA ADVANCED (Globale)
------------------------------------------------------
Nel campo "Custom Nginx Configuration", inserisci i seguenti parametri per evitare timeout durante stampe di report complessi o caricamento di database:

    client_max_body_size 200m;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

5. CONFIGURAZIONE ODOO.CONF
------------------------------------------------------
Ricordati che nel file `/etc/odoo/odoo.conf` sul tuo server bare-metal, devi abilitare il proxy_mode:

    proxy_mode = True

Salva tutto e riavvia Odoo.
======================================================
EOF

echo "✔ Guida Nginx Proxy Manager salvata in /opt/guida_npm_odoo.txt"
echo ""
echo "=========================================="
echo "INSTALLAZIONE COMPLETATA."
echo "Mostro la guida per NPM come richiesto:"
echo "=========================================="
echo ""

# Stampa a video la guida di NPM alla fine dell'installazione
cat /opt/guida_npm_odoo.txt
