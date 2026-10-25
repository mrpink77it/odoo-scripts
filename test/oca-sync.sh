#!/bin/bash

# ==============================================================================
# CONFIGURAZIONE AMBIENTE
# Modifica questi percorsi in base alla struttura del tuo server
# ==============================================================================
BASE_DIR="/opt/odoo"
OCA_REPOS_DIR="$BASE_DIR/oca_repos"
CUSTOM_ADDONS_DIR="$BASE_DIR/custom_addons"
# Path all'eseguibile pip del tuo Virtual Environment (raccomandato)
PIP_CMD="/opt/odoo/venv/bin/pip" 

# ==============================================================================
# COLORI PER OUTPUT
# ==============================================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ==============================================================================
# 1. INSTALLAZIONE DIPENDENZE DI SISTEMA (DEBIAN/UBUNTU)
# ==============================================================================
echo -e "${BLUE}>>> Verifica e installazione delle dipendenze di sistema...${NC}"

# Lista dei pacchetti da installare
PACKAGES=(
    # Tool base per lo script
    "git"
    "curl"
    "jq"
    # Python e Virtual Environment
    "python3-full"
    "python3-dev"
    "python3-venv"
    # Utility di sistema richieste
    "mc"
    "btop"
    # Tool di compilazione e librerie C (fondamentali per le dipendenze pip di Odoo/OCA)
    "build-essential"
    "libpq-dev"       # Per psycopg2 (PostgreSQL)
    "libxml2-dev"     # Per lxml
    "libxslt1-dev"    # Per lxml
    "libldap2-dev"    # Per python-ldap
    "libsasl2-dev"    # Per python-ldap
    "libssl-dev"      # Per crittografia e sicurezza
)

# Funzione per installare i pacchetti
install_packages() {
    # Aggiorna la lista dei pacchetti
    sudo apt-get update -qq

    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg -l | grep -q -w "^ii  $pkg"; then
            echo -e "${YELLOW}Installazione di $pkg...${NC}"
            sudo apt-get install -y "$pkg"
        else
            echo -e "${GREEN}$pkg è già installato.${NC}"
        fi
    done
}

# Verifica se sudo è disponibile o se lo script è eseguito come root
if [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        echo -e "${YELLOW}Verranno richiesti i privilegi di root per installare i pacchetti di sistema via apt.${NC}"
        install_packages
    else
         echo -e "${RED}Errore: Lo script non è eseguito come root e 'sudo' non è disponibile. Impossibile installare i pacchetti.${NC}"
         exit 1
    fi
else
    install_packages
fi

# ==============================================================================
# 2. PRE-FLIGHT CHECKS AMBIENTE PYTHON
# ==============================================================================
if [ ! -f "$PIP_CMD" ]; then
    echo -e "\n${YELLOW}Attenzione: Eseguibile pip non trovato in $PIP_CMD.${NC}"
    echo -e "È fortemente raccomandato usare un Virtual Environment su Debian/Ubuntu (PEP 668)."
    read -p "Vuoi usare il pip di sistema (es. pip3) ignorando il venv? (s/n): " use_sys_pip
    if [ "$use_sys_pip" = "s" ]; then
        PIP_CMD="pip3"
    else
        echo -e "${RED}Interrotto.${NC} Assicurati di creare il venv in /opt/odoo/venv o modifica la variabile PIP_CMD."
        exit 1
    fi
fi

mkdir -p "$OCA_REPOS_DIR"
mkdir -p "$CUSTOM_ADDONS_DIR"

# ==============================================================================
# 3. PROMPT VERSIONE ODOO E RECUPERO REPO GITHUB
# ==============================================================================
echo ""
read -p "Inserisci la versione/branch di Odoo da gestire (es. 18.0): " ODOO_BRANCH
if [ -z "$ODOO_BRANCH" ]; then
    echo -e "${RED}Errore: Versione non inserita.${NC}"
    exit 1
fi

echo -e "${BLUE}>>> Recupero la lista dei repository OCA via API GitHub...${NC}"

# Paginazione per recuperare tutti i repository
PAGE=1
REPOS=()
while :; do
    RESPONSE=$(curl -s "https://api.github.com/orgs/OCA/repos?per_page=100&page=${PAGE}")
    
    # Controllo errore API (es. Rate Limit)
    if echo "$RESPONSE" | jq -e 'has("message")' > /dev/null; then
         MSG=$(echo "$RESPONSE" | jq -r '.message')
         echo -e "${RED}Errore API GitHub: $MSG${NC}"
         exit 1
    fi

    CURRENT_REPOS=$(echo "$RESPONSE" | jq -r '.[].clone_url' 2>/dev/null)
    if [ -z "$CURRENT_REPOS" ]; then
        break
    fi
    
    # shellcheck disable=SC2206
    REPOS+=($CURRENT_REPOS)
    ((PAGE++))
done

TOTAL_REPOS=${#REPOS[@]}
echo -e "${GREEN}Trovati $TOTAL_REPOS repository nell'organizzazione OCA.${NC}"

# ==============================================================================
# 4. ELABORAZIONE REPOSITORY
# ==============================================================================
for REPO_URL in "${REPOS[@]}"; do
    REPO_NAME=$(basename "$REPO_URL" .git)
    TARGET_DIR="$OCA_REPOS_DIR/$REPO_NAME"

    echo -e "\n${BLUE}--- Elaborazione: $REPO_NAME ---${NC}"

    # Controlla se il branch richiesto esiste per questo repository
    BRANCH_EXISTS=$(git ls-remote --heads "$REPO_URL" "$ODOO_BRANCH" | wc -l)
    
    if [ "$BRANCH_EXISTS" -eq 0 ]; then
        echo -e "${YELLOW}Branch '$ODOO_BRANCH' non trovato in $REPO_NAME. Salto.${NC}"
        continue
    fi

    # Clone o Pull
    if [ -d "$TARGET_DIR" ]; then
        echo -e "Directory esistente. Eseguo ${GREEN}git pull${NC}..."
        cd "$TARGET_DIR" || continue
        git checkout "$ODOO_BRANCH" >/dev/null 2>&1
        git pull origin "$ODOO_BRANCH"
    else
        echo -e "Eseguo ${GREEN}git clone${NC}..."
        git clone -b "$ODOO_BRANCH" --single-branch "$REPO_URL" "$TARGET_DIR"
    fi

    # Creazione Symlink per i moduli
    echo -e "Aggiornamento link simbolici in $CUSTOM_ADDONS_DIR..."
    for manifest in "$TARGET_DIR"/*/__manifest__.py; do
        if [ -f "$manifest" ]; then
            MODULE_DIR=$(dirname "$manifest")
            MODULE_NAME=$(basename "$MODULE_DIR")
            ln -sfn "$MODULE_DIR" "$CUSTOM_ADDONS_DIR/$MODULE_NAME"
            echo "  -> Linkato: $MODULE_NAME"
        fi
    done

    # Installazione dipendenze Python
    if [ -f "$TARGET_DIR/requirements.txt" ]; then
        echo -e "Trovato requirements.txt. Eseguo ${GREEN}pip install${NC}..."
        # L'utilizzo di sudo non viene applicato a pip se stiamo puntando al venv
        $PIP_CMD install -r "$TARGET_DIR/requirements.txt"
    else
        echo -e "Nessun requirements.txt trovato."
    fi

done

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${GREEN}Operazione completata con successo!${NC}"
echo -e "I moduli sono stati scaricati in: $OCA_REPOS_DIR"
echo -e "I link simbolici sono pronti in: $CUSTOM_ADDONS_DIR"
echo -e "${GREEN}======================================================================${NC}"
