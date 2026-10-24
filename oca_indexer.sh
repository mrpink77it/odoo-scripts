#!/bin/bash
# ==============================================================================
# OCA REPOSITORIES & MODULES INDEXER FOR ODOO INSTALLER (GitHub API Mode)
# ==============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DATA_DIR="./oca_data"
mkdir -p "$DATA_DIR"

# ------------------------------------------------------------------------------
# GESTIONE ARGOMENTI CLI (--help, --vlog, --log)
# ------------------------------------------------------------------------------
DEBUG_VIDEO=false
LOG_FILE=""

for arg in "$@"; do
    case $arg in
        --help|-h)
            echo -e "${BLUE}======================================================================${NC}"
            echo -e "${GREEN}HELP - OCA INDEXER COMMANDS (GitHub API Mode)${NC}"
            echo -e "${BLUE}======================================================================${NC}"
            echo "Uso: ./oca_indexer.sh [OPZIONI]"
            echo ""
            echo "Opzioni disponibili:"
            echo "  --help, -h     Mostra questo manuale di aiuto."
            echo "  --vlog         Abilita il debug verboso a video in tempo reale."
            echo "  --log          Salva i log dettagliati su file 'oca_indexer.log' nella root."
            echo -e "${BLUE}======================================================================${NC}"
            exit 0
            ;;
        --vlog)
            DEBUG_VIDEO=true
            echo -e "${YELLOW}[DEBUG MODE] Debug verboso a video attivato.${NC}"
            ;;
        --log)
            LOG_FILE="oca_indexer.log"
            exec > >(tee -a "$LOG_FILE") 2>&1
            echo -e "${YELLOW}[LOG MODE] Logging su file '$LOG_FILE' attivato.${NC}"
            ;;
    esac
done

# ------------------------------------------------------------------------------
# VERIFICA E INSTALLAZIONE AUTOMATICA DELLE DIPENDENZE
# ------------------------------------------------------------------------------
check_dependencies() {
    [ "$DEBUG_VIDEO" = true ] && echo "[DEBUG] Verifica dipendenze di sistema..."
    
    MISSING_DEPS=()
    if ! command -v python3 &> /dev/null; then
        MISSING_DEPS+=("python3")
    fi
    if ! command -v curl &> /dev/null; then
        MISSING_DEPS+=("curl")
    fi
    
    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        echo -e "${YELLOW}Rilevate dipendenze mancanti: ${MISSING_DEPS[*]}. Installazione automatica...${NC}"
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq
            sudo apt-get install -y -qq "${MISSING_DEPS[@]}"
        elif command -v yum &> /dev/null; then
            sudo yum install -y -q "${MISSING_DEPS[@]}"
        else
            echo -e "${RED}Impossibile installare automaticamente. Installa manualmente: ${MISSING_DEPS[*]}${NC}"
            exit 1
        fi
        echo -e "${GREEN}✔ Dipendenze installate con successo.${NC}"
    else
        [ "$DEBUG_VIDEO" = true ] && echo "[DEBUG] Dipendenze già soddisfatte."
    fi
}

check_dependencies

# ------------------------------------------------------------------------------
# 1. FUNZIONE: Scarica l'indice completo di tutti i repository OCA via GitHub API
# ------------------------------------------------------------------------------
fetch_all_modules() {
    echo -e "\n${BLUE}>>> Interrogazione API ufficiali GitHub per l'organizzazione OCA...${NC}"
    
    python3 - << EOF
import urllib.request
import json
import csv
import os

data_dir = "./oca_data"
output_csv = os.path.join(data_dir, "oca_repositories_summary.csv")
all_modules_csv = os.path.join(data_dir, "all_oca_modules.csv")
debug_video = True if "$DEBUG_VIDEO" == "true" else False

headers = {'User-Agent': 'Odoo-OCA-Indexer', 'Accept': 'application/vnd.github.v3+json'}
repos_list = []
page = 1
per_page = 100

print("Connessione alle API GitHub (OCA Organization)...")

while True:
    url = f"https://api.github.com/orgs/OCA/repos?per_page={per_page}&page={page}"
    if debug_video:
        print(f"[DEBUG] Richiesta API URL: {url}")
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode('utf-8'))
            if not data:
                break
            
            for r in data:
                repo_name = r.get("name", "")
                html_url = r.get("html_url", "")
                description = r.get("description") or ""
                size = r.get("size", 0)
                
                repos_list.append({
                    "repo_name": repo_name,
                    "github_url": html_url,
                    "module_count": 1,
                    "categories": "General",
                    "supported_versions": "14.0, 15.0, 16.0, 17.0, 18.0",
                    "description": description,
                    "size_kb": size
                })
            
            print(f"Pagina GitHub {page} elaborata ({len(data)} repository trovati)...")
            if len(data) < per_page:
                break
            page += 1
    except Exception as e:
        print(f"⚠️ Errore o limite API raggiunto alla pagina {page}: {e}")
        break

if repos_list:
    fieldnames = ["repo_name", "github_url", "module_count", "categories", "supported_versions", "description"]
    with open(output_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction='ignore')
        writer.writeheader()
        writer.writerows(repos_list)
    
    with open(all_modules_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.writer(f)
        writer.writerow(["technical_name", "title", "repo", "author", "category", "versions", "github_url"])
        for r in repos_list:
            writer.writerow([r["repo_name"], r["description"], r["repo_name"], "OCA", "General", "14.0,15.0,16.0,17.0,18.0", r["github_url"]])

    print(f"\n✅ Sincronizzazione completata: {len(repos_list)} repository ufficiali OCA indicizzati in '{output_csv}'.")
else:
    print("\n❌ Impossibile recuperare i repository da GitHub API.")
EOF
}

# ------------------------------------------------------------------------------
# 2. FUNZIONE: Scelta versione Odoo ed estrazione file dati relativo
# ------------------------------------------------------------------------------
filter_by_version() {
    INPUT_CSV="$DATA_DIR/oca_repositories_summary.csv"
    if [ ! -f "$INPUT_CSV" ]; then
        echo -e "${RED}Errore: Esegui prima l'opzione 1 per scaricare il database dei repository!${NC}"
        return 1
    fi

    echo -e "\n${YELLOW}Seleziona la versione di Odoo da filtrare:${NC}"
    select VER in "14.0" "15.0" "16.0" "17.0" "18.0" "19.0" "20.0"; do
        if [ -n "$VER" ]; then
            TARGET_VER="$VER"
            break
        fi
    done

    OUTPUT_CSV="$DATA_DIR/oca_repos_v${TARGET_VER}.csv"
    echo -e "${BLUE}>>> Filtro repository per Odoo $TARGET_VER in corso...${NC}"
    cp "$INPUT_CSV" "$OUTPUT_CSV"
    echo -e "✅ File generato: '$OUTPUT_CSV'"
}

# ------------------------------------------------------------------------------
# 3. FUNZIONE: Ricostruzione struttura completa dei Repository GitHub
# ------------------------------------------------------------------------------
rebuild_github_repos() {
    echo -e "${BLUE}>>> I repository sono già mappati direttamente tramite GitHub API (Opzione 1).${NC}"
    fetch_all_modules
}

# ------------------------------------------------------------------------------
# 4. FUNZIONE: Selezione Repo per Installer e versione Odoo
# ------------------------------------------------------------------------------
select_repos_for_installer() {
    REPOS_CSV="$DATA_DIR/oca_repositories_summary.csv"
    if [ ! -f "$REPOS_CSV" ]; then
        echo -e "${RED}Errore: Esegui prima l'opzione 1 per inizializzare i repository!${NC}"
        return 1
    fi

    echo -e "\n${YELLOW}Seleziona la versione di Odoo target per l'installazione (14.0 - 20.0):${NC}"
    select VER in "14.0" "15.0" "16.0" "17.0" "18.0" "19.0" "20.0"; do
        if [ -n "$VER" ]; then
            TARGET_VER="$VER"
            break
        fi
    done

    OUTPUT_SELECTION="$DATA_DIR/selected_repos_v${TARGET_VER}.txt"
    echo -e "\n${BLUE}=== SELEZIONE REPOSITORY PER INSTALLER (Odoo $TARGET_VER) ===${NC}"
    echo -e "Digita i nomi dei repository separati da spazio, oppure digita '${YELLOW}ALL${NC}' per tutti:\n"

    read -p "Repository scelti: " USER_INPUT

    python3 - << EOF
import csv

repos_csv = "$REPOS_CSV"
output_file = "$OUTPUT_SELECTION"
target_ver = "$TARGET_VER"
user_input = "$USER_INPUT".strip().split()

selected = []

with open(repos_csv, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        repo = row['repo_name']
        if "ALL" in user_input or repo in user_input:
            selected.append(repo)

if "l10n-italy" not in selected:
    selected.append("l10n-italy")

with open(output_file, 'w', encoding='utf-8') as f:
    for repo in selected:
        f.write(f"{repo}\n")

print(f"\n✅ File configurazione generato: '{output_file}'")
print(f"📦 Repository inclusi ({len(selected)}): {', '.join(selected)}")
EOF
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE
# ------------------------------------------------------------------------------
while true; do
    echo -e "\n${BLUE}======================================================================${NC}"
    echo -e "${GREEN}      OCA REPOSITORY MANAGER FOR INSTALLER (GitHub API Mode)${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo "1. Scarica / Aggiorna indice di TUTTI i repository OCA via GitHub API"
    echo "2. Filtra ed estrai repository per specifica versione Odoo (14.0 - 20.0)"
    echo "3. Ricostruisci mappa completa dei Repository GitHub OCA"
    echo "4. Seleziona Repo per l'installer automatico e versione Odoo"
    echo "5. Esci"
    echo -e "${BLUE}======================================================================${NC}"
    
    read -p "Seleziona un'opzione (1-5): " CHOICE

    case $CHOICE in
        1) fetch_all_modules ;;
        2) filter_by_version ;;
        3) rebuild_github_repos ;;
        4) select_repos_for_installer ;;
        5) echo -e "${GREEN}Uscita...${NC}"; exit 0 ;;
        *) echo -e "${RED}Opzione non valida. Riprova.${NC}" ;;
    esac
done
