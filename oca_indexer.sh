#!/bin/bash
# ==============================================================================
# OCA MODULES & REPOS INDEXER FOR ODOO INSTALLER 
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
# VERIFICA E INSTALLAZIONE AUTOMATICA DELLE DIPENDENZE
# ------------------------------------------------------------------------------
check_dependencies() {
    echo -e "${BLUE}>>> Verifica dipendenze di sistema in corso...${NC}"
    
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
            echo -e "${RED}Errore: Impossibile installare automaticamente i pacchetti. Installa manualmente: ${MISSING_DEPS[*]}${NC}"
            exit 1
        fi
        echo -e "${GREEN}✔ Dipendenze installate con successo.${NC}"
    else
        echo -e "${GREEN}✔ Tutte le dipendenze sono già soddisfatte.${NC}"
    fi
}

# Esegue il controllo dipendenze all'avvio
check_dependencies

# ------------------------------------------------------------------------------
# 1. FUNZIONE: Lettura di tutti i moduli presenti dall'App Store / API OCA
# ------------------------------------------------------------------------------
fetch_all_modules() {
    echo -e "\n${BLUE}>>> Avvio scansione completa dell'App Store OCA...${NC}"
    echo -e "${YELLOW}Questo processo scarica l'indice di tutti i moduli, autori, categorie e versioni.${NC}"
    
    python3 - << 'EOF'
import urllib.request
import json
import csv
import os

data_dir = "./oca_data"
output_csv = os.path.join(data_dir, "all_oca_modules.csv")

headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'}
modules_list = []

page = 1
per_page = 250

print("Connessione all'App Store OCA in corso...")

while True:
    url = f"https://apps.odoo-community.org/api/v1/modules?per_page={per_page}&page={page}"
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as response:
            if response.status != 200:
                break
            data = json.loads(response.read().decode('utf-8'))
            
            items = data.get('items', [])
            if not items:
                if isinstance(data, list):
                    items = data
                else:
                    break
            
            for mod in items:
                technical_name = mod.get('technical_name', mod.get('name', ''))
                title = mod.get('title', mod.get('summary', ''))
                repo = mod.get('repo', mod.get('repository', ''))
                author = mod.get('author', mod.get('maintainer', 'OCA'))
                category = mod.get('category', '')
                versions = ",".join(mod.get('versions', []))
                github_url = mod.get('github_url', f"https://github.com/OCA/{repo}/tree/master/{technical_name}" if repo else "")

                modules_list.append({
                    "technical_name": technical_name,
                    "title": title,
                    "repo": repo,
                    "author": author,
                    "category": category,
                    "versions": versions,
                    "github_url": github_url
                })

            print(f"Pagina {page} elaborata ({len(items)} moduli trovati)...")
            
            if len(items) < per_page:
                break
            page += 1
    except Exception as e:
        print(f"Completato o interrotto alla pagina {page}: {e}")
        break

if modules_list:
    fieldnames = ["technical_name", "title", "repo", "author", "category", "versions", "github_url"]
    with open(output_csv, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(modules_list)
    print(f"\n✅ Salvataggio completato: {len(modules_list)} moduli salvati in '{output_csv}'.")
else:
    print("\n⚠️ Impossibile raggiungere l'API remota.")
EOF
}

# ------------------------------------------------------------------------------
# 2. FUNZIONE: Scelta versione Odoo ed estrazione file dati relativo
# ------------------------------------------------------------------------------
filter_by_version() {
    INPUT_CSV="$DATA_DIR/all_oca_modules.csv"
    if [ ! -f "$INPUT_CSV" ]; then
        echo -e "${RED}Errore: Esegui prima la funzione 1 per scaricare il database dei moduli!${NC}"
        return 1
    fi

    echo -e "\n${YELLOW}Seleziona la versione di Odoo da filtrare:${NC}"
    select VER in "14.0" "15.0" "16.0" "17.0" "18.0" "19.0" "20.0"; do
        if [ -n "$VER" ]; then
            TARGET_VER="$VER"
            break
        fi
    done

    OUTPUT_CSV="$DATA_DIR/oca_modules_v${TARGET_VER}.csv"
    echo -e "${BLUE}>>> Filtro moduli per Odoo $TARGET_VER in corso...${NC}"

    python3 - << EOF
import csv

input_file = "$INPUT_CSV"
output_file = "$OUTPUT_CSV"
target_ver = "$TARGET_VER"

filtered = []
with open(input_file, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        versions = [v.strip() for v in row['versions'].split(',')]
        if target_ver in versions:
            filtered.append(row)

if filtered:
    with open(output_file, 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=reader.fieldnames)
        writer.writeheader()
        writer.writerows(filtered)
    print(f"✅ Estratti {len(filtered)} moduli compatibili con Odoo {target_ver} in '{output_file}'.")
else:
    print(f"⚠️ Nessun modulo trovato per la versione {target_ver}.")
EOF
}

# ------------------------------------------------------------------------------
# 3. FUNZIONE: Ricostruzione struttura completa dei Repository GitHub
# ------------------------------------------------------------------------------
rebuild_github_repos() {
    INPUT_CSV="$DATA_DIR/all_oca_modules.csv"
    if [ ! -f "$INPUT_CSV" ]; then
        echo -e "${RED}Errore: Esegui prima la funzione 1 per scaricare il database dei moduli!${NC}"
        return 1
    fi

    OUTPUT_CSV="$DATA_DIR/oca_repositories_summary.csv"
    echo -e "${BLUE}>>> Raggruppamento dei moduli nei rispettivi repository GitHub...${NC}"

    python3 - << EOF
import csv
from collections import defaultdict

input_file = "$INPUT_CSV"
output_file = "$OUTPUT_CSV"

repos = defaultdict(lambda: {"module_count": 0, "modules": [], "categories": set(), "versions": set()})

with open(input_file, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        repo_name = row['repo'].strip()
        if not repo_name:
            continue
        repos[repo_name]["module_count"] += 1
        repos[repo_name]["modules"].append(row['technical_name'])
        if row['category']:
            repos[repo_name]["categories"].add(row['category'])
        for v in row['versions'].split(','):
            if v.strip():
                repos[repo_name]["versions"].add(v.strip())

rows = []
for repo, info in sorted(repos.items()):
    rows.append({
        "repo_name": repo,
        "github_url": f"https://github.com/OCA/{repo}",
        "module_count": info["module_count"],
        "categories": ", ".join(sorted(info["categories"])),
        "supported_versions": ", ".join(sorted(info["versions"])),
        "sample_modules": ", ".join(info["modules"][:5])
    })

fieldnames = ["repo_name", "github_url", "module_count", "categories", "supported_versions", "sample_modules"]
with open(output_file, 'w', newline='', encoding='utf-8') as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

print(f"✅ Ricostruzione completata: {len(rows)} repository unici individuati in '{output_file}'.")
EOF
}

# ------------------------------------------------------------------------------
# 4. FUNZIONE: Selezione interattiva Repo per Installer e versione Odoo
# ------------------------------------------------------------------------------
select_repos_for_installer() {
    REPOS_CSV="$DATA_DIR/oca_repositories_summary.csv"
    if [ ! -f "$REPOS_CSV" ]; then
        echo -e "${RED}Errore: Esegui prima la funzione 3 per ricostruire la lista dei repository!${NC}"
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
    echo -e "Digita il nome dei repository che desideri includere nell'installazione."
    echo -e "Esempio: ${GREEN}web server-tools account-financial-reporting l10n-italy${NC}"
    echo -e "Digita '${YELLOW}ALL${NC}' per selezionare tutti i repo compatibili, oppure inserisci i nomi separati da spazio:\n"

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
        versions = [v.strip() for v in row['supported_versions'].split(',')]
        
        if target_ver in versions or not row['supported_versions']:
            if "ALL" in user_input or repo in user_input:
                selected.append(repo)

if "l10n-italy" not in selected:
    selected.append("l10n-italy")

with open(output_file, 'w', encoding='utf-8') as f:
    for repo in selected:
        f.write(f"{repo}\n")

print(f"\n✅ File configurazione installer generato con successo: '{output_file}'")
print(f"📦 Repository inclusi ({len(selected)}): {', '.join(selected)}")
EOF
}

# ------------------------------------------------------------------------------
# MENU PRINCIPALE INTERATTIVO
# ------------------------------------------------------------------------------
while true; do
    echo -e "\n${BLUE}======================================================================${NC}"
    echo -e "${GREEN}      OCA MODULES & REPOSITORY MANAGER FOR INSTALLER${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo "1. Scarica / Aggiorna indice di TUTTI i moduli OCA, versioni, repo e autori"
    echo "2. Filtra ed estrai file moduli per specifica versione Odoo (14.0 - 20.0)"
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
