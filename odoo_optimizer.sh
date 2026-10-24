#!/bin/bash
# ==============================================================================
# ODOO & POSTGRESQL ADVANCED AUTO-TUNING & BENCHMARK SCRIPT
# Con supporto per --test (Dry-Run), --debug (Verbose) e --help
# ==============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# GESTIONE ARGOMENTI CLI (--test, --debug, --help)
# ------------------------------------------------------------------------------
DRY_RUN=false
DEBUG_MODE=false

show_help() {
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${GREEN}MANUALE D'USO - ODOO & POSTGRESQL OPTIMIZER${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo "Uso: sudo bash odoo_optimizer.sh [OPZIONI]"
    echo ""
    echo "Opzioni disponibili:"
    echo "  --test       Esegue una simulazione (dry-run): non modifica alcun file"
    echo "               né riavvia servizi, ma genera un report dettagliato con i"
    echo "               parametri hardware raccomandati."
    echo "  --debug      Attiva il debug atomico e verboso mostrando ogni comando"
    echo "               e operazione eseguita in tempo reale."
    echo "  --help, -h   Mostra questo manuale di aiuto."
    echo -e "${BLUE}======================================================================${NC}"
    exit 0
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --test) DRY_RUN=true; shift ;;
        --debug) DEBUG_MODE=true; shift ;;
        --help|-h) show_help ;;
        *) echo -e "${RED}Opzione sconosciuta: $1${NC}"; show_help ;;
    esac
done

if [ "$DEBUG_MODE" = true ]; then
    set -x
    echo -e "${YELLOW}[DEBUG MODE ATTIVO] Tracciamento atomico abilitato.${NC}"
fi

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Errore: Questo script deve essere eseguito come root (sudo).${NC}"
    exit 1
fi

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}      OTTIMIZZAZIONE AVANZATA & BENCHMARK ODOO / POSTGRESQL${NC}"
[ "$DRY_RUN" = true ] && echo -e "${YELLOW}               [MODALITÀ TEST / DRY-RUN ATTIVA]                  ${NC}"
echo -e "${BLUE}======================================================================${NC}"

# ------------------------------------------------------------------------------
# 1. RILEVAMENTO HARDWARE E CALCOLO PARAMETRI (AUTO-TUNING)
# ------------------------------------------------------------------------------
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
TOTAL_CPUs=$(nproc)

[ "$DEBUG_MODE" = true ] && echo "[DEBUG] RAM rilevata: ${TOTAL_RAM_MB}MB, CPU Cores: ${TOTAL_CPUs}"

echo -e "Hardware rilevato: ${GREEN}$TOTAL_CPUs CPU Cores${NC} | ${GREEN}$TOTAL_RAM_MB MB di RAM${NC}"

PG_SHARED_BUFFERS=$((TOTAL_RAM_MB / 4))
[ $PG_SHARED_BUFFERS -lt 128 ] && PG_SHARED_BUFFERS=128

PG_EFFECTIVE_CACHE=$(( (TOTAL_RAM_MB * 3) / 4 ))
PG_WORK_MEM="64MB"
[ $TOTAL_RAM_MB -ge 16384 ] && PG_WORK_MEM="128MB"
[ $TOTAL_RAM_MB -ge 32768 ] && PG_WORK_MEM="256MB"

PG_MAINT_MEM="512MB"
[ $TOTAL_RAM_MB -ge 16384 ] && PG_MAINT_MEM="1GB"

ODOO_WORKERS=$(( (TOTAL_CPUs * 2) + 1 ))
MAX_CONNECTIONS=$(( (ODOO_WORKERS * 2) + 20 ))

echo -e "\n${YELLOW}Parametri calcolati per il tuning:${NC}"
echo -e " • shared_buffers      : ${BLUE}${PG_SHARED_BUFFERS}MB${NC}"
echo -e " • effective_cache_size: ${BLUE}${PG_EFFECTIVE_CACHE}MB${NC}"
echo -e " • work_mem            : ${BLUE}${PG_WORK_MEM}${NC}"
echo -e " • maintenance_work_mem: ${BLUE}${PG_MAINT_MEM}${NC}"
echo -e " • Odoo HTTP Workers   : ${BLUE}$ODOO_WORKERS${NC}"
echo -e " • PostgreSQL Max Conn : ${BLUE}$MAX_CONNECTIONS${NC}"

# Seleziona la modalità di test (--test)
if [ "$DRY_RUN" = true ]; then
    echo -e "\n${YELLOW}======================================================================${NC}"
    echo -e "${GREEN}            REPORT SIMULAZIONE (--test) COMPLETATO${NC}"
    echo -e "${YELLOW}======================================================================${NC}"
    echo -e "In modalità test nessun file di configurazione è stato modificato."
    echo -e "I valori sopra indicati verrebbero applicati a postgresql.conf e odoo.conf."
    echo -e "${BLUE}======================================================================${NC}"
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. APPLICAZIONE CONFIGURAZIONE POSTGRESQL
# ------------------------------------------------------------------------------
PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -n 1)

if [ -n "$PG_VERSION" ]; then
    PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"
    echo -e "\n${BLUE}>>> Aggiornamento configurazione PostgreSQL ($PG_CONF_FILE)...${NC}"
    
    if [ -f "$PG_CONF_FILE" ]; then
        cp "$PG_CONF_FILE" "${PG_CONF_FILE}.bak_$(date +%F_%T)"

        sed -i "s/^#*shared_buffers =.*/shared_buffers = ${PG_SHARED_BUFFERS}MB/" "$PG_CONF_FILE"
        sed -i "s/^#*effective_cache_size =.*/effective_cache_size = ${PG_EFFECTIVE_CACHE}MB/" "$PG_CONF_FILE"
        sed -i "s/^#*work_mem =.*/work_mem = ${PG_WORK_MEM}/" "$PG_CONF_FILE"
        sed -i "s/^#*maintenance_work_mem =.*/maintenance_work_mem = ${PG_MAINT_MEM}/" "$PG_CONF_FILE"
        sed -i "s/^#*max_connections =.*/max_connections = ${MAX_CONNECTIONS}/" "$PG_CONF_FILE"
        
        sed -i "s/^#*random_page_cost =.*/random_page_cost = 1.1/" "$PG_CONF_FILE"
        sed -i "s/^#*effective_io_concurrency =.*/effective_io_concurrency = 200/" "$PG_CONF_FILE"

        systemctl restart postgresql
        echo -e "${GREEN}✔ PostgreSQL riavviato con le nuove impostazioni.${NC}"
    else
        echo -e "${RED}⚠️ File postgresql.conf non trovato nel percorso standard.${NC}"
    fi
else
    echo -e "${RED}⚠️ Nessun cluster PostgreSQL attivo rilevato.${NC}"
fi

# ------------------------------------------------------------------------------
# 3. APPLICAZIONE CONFIGURAZIONE ODOO (WORKERS & MEMORY LIMITS)
# ------------------------------------------------------------------------------
OE_CONFIG="/etc/odoo.conf"
if [ -f "$OE_CONFIG" ]; then
    echo -e "\n${BLUE}>>> Aggiornamento configurazione Odoo ($OE_CONFIG)...${NC}"
    cp "$OE_CONFIG" "${OE_CONFIG}.bak_$(date +%F_%T)"

    if grep -q "workers =" "$OE_CONFIG"; then
        sed -i "s/^workers =.*/workers = $ODOO_WORKERS/" "$OE_CONFIG"
    else
        sed -i "/\[options\]/a workers = $ODOO_WORKERS" "$OE_CONFIG"
    fi

    systemctl restart odoo 2>/dev/null || echo -e "${YELLOW}Servizio Odoo non ancora attivo o gestito manualmente.${NC}"
    echo -e "${GREEN}✔ Configurazione Odoo aggiornata.${NC}"
fi

# ------------------------------------------------------------------------------
# 4. BENCHMARK AUTOMATICO (PGBENCH & HTTP TEST)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${GREEN}                 AVVIO BENCHMARK DELLE PRESTAZIONI${NC}"
echo -e "${BLUE}======================================================================${NC}"

if command -v pgbench &> /dev/null && [ -n "$PG_VERSION" ]; then
    echo -e "${YELLOW}Esecuzione benchmark PostgreSQL (pgbench) su database di test...${NC}"
    sudo -u postgres createdb odoo_opt_test_db 2>/dev/null || true
    sudo -u postgres pgbench -i -s 5 odoo_opt_test_db >/dev/null 2>&1
    
    echo -e "Risultato test di carico (10 client concorrenti, 50 transazioni):"
    sudo -u postgres pgbench -c 10 -j 2 -t 50 odoo_opt_test_db
    
    sudo -u postgres dropdb odoo_opt_test_db 2>/dev/null || true
    echo -e "${GREEN}✔ Benchmark del database completato con successo.${NC}"
fi

if command -v ab &> /dev/null; then
    echo -e "\n${YELLOW}Esecuzione stress test HTTP su Odoo (porta 8069)...${NC}"
    ab -n 50 -c 5 http://127.0.0.1:8069/web/database/selector 2>/dev/null || echo -e "${YELLOW}Servizio HTTP Odoo non raggiungibile per il test.${NC}"
fi

echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${GREEN} Ottimizzazione e Benchmark completati con successo!${NC}"
echo -e "${BLUE}======================================================================${NC}"
