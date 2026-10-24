#!/bin/bash
# ==============================================================================
# OCA REPOSITORIES INDEXER -> oca.txt (Clean & Essential)
# ==============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

OUTPUT_TXT="oca.txt"

# ------------------------------------------------------------------------------
# GESTIONE ARGOMENTI CLI (--help, --vlog, --log)
# ------------------------------------------------------------------------------
DEBUG_VIDEO=false
LOG_FILE=""

for arg in "$@"; do
    case $arg in
        --help|-h)
            echo -e "${BLUE}======================================================================${NC}"
            echo -e "${GREEN}HELP - OCA INDEXER${NC}"
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
# ESECUZIONE PRINCIPALE: Generazione di oca.txt
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}>>> Generazione file '$OUTPUT_TXT' dai repository ufficiali OCA...${NC}"

python3 - << EOF
import urllib.request
import json
import os

output_txt = "$OUTPUT_TXT"
debug_video = True if "$DEBUG_VIDEO" == "true" else False

headers = {'User-Agent': 'Odoo-OCA-Indexer', 'Accept': 'application/vnd.github.v3+json'}
urls_list = []
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
                repo_name = r.get("name", "").lower()
                html_url = r.get("html_url", "")
                
                # Esclusione unit test e openupgrade
                if "test" in repo_name or "openupgrade" in repo_name:
                    if debug_video:
                        print(f"[DEBUG] Escluso repository: {repo_name}")
                    continue
                
                if html_url and html_url not in urls_list:
                    urls_list.append(html_url)
            
            print(f"Pagina GitHub {page} elaborata ({len(data)} repository analizzati)...")
            if len(data) < per_page:
                break
            page += 1
    except Exception as e:
        print(f"⚠️ Errore o limite API raggiunto alla pagina {page}: {e}")
        break

if urls_list:
    # Ordinamento alfabetico pulito
    urls_list = sorted(list(set(urls_list)))
    
    with open(output_txt, 'w', encoding='utf-8') as f:
        for url in urls_list:
            f.write(f"{url}\n")
            
    print(f"\n✅ Operazione completata: '{output_txt}' generato con successo.")
    print(f"📦 Totale repository inclusi: {len(urls_list)}")
else:
    print("\n❌ Nessun repository recuperato.")
EOF
