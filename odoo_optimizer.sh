#!/bin/bash

set -e

# ==============================================================================
# OPZIONI CLI (--help, --test, --debug)
# ==============================================================================
DEBUG_MODE=false
BENCHMARK_ONLY=false

for arg in "$@"; do
    case $arg in
        --debug)
            DEBUG_MODE=true
            set -x
            shift
            ;;
        --test)
            BENCHMARK_ONLY=true
            shift
            ;;
        --help|-h)
            echo "======================================================================"
            echo "ODOO OPTIMIZER & BENCHMARK DASHBOARD"
            echo "======================================================================"
            echo "Uso: sudo ./odoo_optimizer.sh [OPZIONI]"
            echo ""
            echo "Opzioni disponibili:"
            echo "  --test     Esegue solo il benchmark delle prestazioni senza applicare modifiche."
            echo "  --debug    Mostra il tracciamento dei comandi a schermo (set -x)."
            echo "  --help     Mostra questo manuale."
            echo "======================================================================"
            exit 0
            ;;
    esac
done

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Errore: Questo script deve essere eseguito come root (sudo).${NC}"
    exit 1
fi

OE_USER="odoo"
OE_CONFIG="/etc/odoo.conf"
BENCH_DB="odoo_bench_temp"

# ==============================================================================
# HARDWARE DETECTION & COMPUTATION
# ==============================================================================
TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
TOTAL_CPUS=$(nproc)

PG_SHARED_BUFFERS=$((TOTAL_RAM_MB / 4))
[ $PG_SHARED_BUFFERS -lt 128 ] && PG_SHARED_BUFFERS=128
PG_EFFECTIVE_CACHE=$(( (TOTAL_RAM_MB * 3) / 4 ))
PG_WORK_MEM=$(( (TOTAL_RAM_MB / TOTAL_CPUS) / 8 ))
[ $PG_WORK_MEM -lt 16 ] && PG_WORK_MEM=16
[ $PG_WORK_MEM -gt 256 ] && PG_WORK_MEM=256
PG_MAINT_WORK_MEM=$((TOTAL_RAM_MB / 16))
[ $PG_MAINT_WORK_MEM -lt 64 ] && PG_MAINT_WORK_MEM=64
[ $PG_MAINT_WORK_MEM -gt 2048 ] && PG_MAINT_WORK_MEM=2048

ODOO_WORKERS=$(( (TOTAL_CPUS * 2) + 1 ))
LIMIT_MEMORY_SOFT=$(( 1024 * 1024 * 1024 * 2 ))      # 2 GB
LIMIT_MEMORY_HARD=$(( 1024 * 1024 * 1024 * 2 + 512 * 1024 * 1024 )) # 2.5 GB

PG_VERSION=$(pg_lsclusters -h 2>/dev/null | awk '{print $1}' | head -n 1)
if [ -z "$PG_VERSION" ]; then
    PG_VERSION="16"
fi
PG_CONF_FILE="/etc/postgresql/$PG_VERSION/main/postgresql.conf"

# ==============================================================================
# FUNZIONE ESECUZIONE BENCHMARK DIVERSIFICATO
# ==============================================================================
run_stress_benchmark() {
    local label=$1
    echo -e "\n${BLUE}>>> Preparazione ambiente di test database ($label)...${NC}"
    
    # Ricreazione database di test isolato
    sudo -u postgres dropdb --if-exists "$BENCH_DB" >/dev/null 2>&1 || true
    sudo -u postgres createdb "$BENCH_DB" >/dev/null 2>&1
    
    # Inizializzazione pgbench con Scaling Factor 10 (tabella da circa 1 milione di righe)
    sudo -u postgres pgbench -i -s 10 "$BENCH_DB" >/dev/null 2>&1
    
    echo -e "${YELLOW}Esecuzione Stress Test multi-livello su $BENCH_DB...${NC}"

    # TEST 1: CARICO BASE (10 Client, 100 Transazioni)
    echo -n "  • Live Stress 1/3 (Carico Base - 10 client concorrenti)... "
    OUT1=$(sudo -u postgres pgbench -c 10 -j 2 -t 100 --latency-limit=1000 "$BENCH_DB" 2>&1)
    TPS1=$(echo "$OUT1" | grep "tps = " | head -n 1 | awk '{print $3}')
    LAT1=$(echo "$OUT1" | grep "latency average = " | awk '{print $4}')

    # TEST 2: CARICO MEDIO (25 Client, 200 Transazioni)
    echo -n -e "\r  • Live Stress 2/3 (Carico Medio - 25 client concorrenti)... "
    OUT2=$(sudo -u postgres pgbench -c 25 -j 4 -t 200 --latency-limit=1000 "$BENCH_DB" 2>&1)
    TPS2=$(echo "$OUT2" | grep "tps = " | head -n 1 | awk '{print $3}')
    LAT2=$(echo "$OUT2" | grep "latency average = " | awk '{print $4}')

    # TEST 3: CARICO ALTO CON SELEZIONI E UPDATE PARALLELI (50 Client, 300 Transazioni)
    echo -n -e "\r  • Live Stress 3/3 (Carico Alto - 50 client concorrenti)...  "
    OUT3=$(sudo -u postgres pgbench -c 50 -j $TOTAL_CPUS -t 300 --latency-limit=2000 "$BENCH_DB" 2>&1)
    TPS3=$(echo "$OUT3" | grep "tps = " | head -n 1 | awk '{print $3}')
    LAT3=$(echo "$OUT3" | grep "latency average = " | awk '{print $4}')

    echo -e "\r  ${GREEN}✔ Stress Test ($label) completato con successo.${NC}                          "

    # Rimozione database temporaneo
    sudo -u postgres dropdb "$BENCH_DB" >/dev/null 2>&1 || true

    # Esportazione risultati
    eval "${label}_TPS1=\"$TPS1\""
    eval "${label}_LAT1=\"$LAT1\""
    eval "${label}_TPS2=\"$TPS2\""
    eval "${label}_LAT2=\"$LAT2\""
    eval "${label}_TPS3=\"$TPS3\""
    eval "${label}_LAT3=\"$LAT3\""
}

# ==============================================================================
# FASE 1: BENCHMARK INIZIALE (PRIMA)
# ==============================================================================
echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}    ODOO & POSTGRESQL OPTIMIZER - PERFORMANCE DASHBOARD${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e "Hardware rilevato: ${BOLD}${TOTAL_CPUS} CPU Cores${NC} | ${BOLD}${TOTAL_RAM_MB} MB di RAM${NC}"

run_stress_benchmark "BEFORE"

if [ "$BENCHMARK_ONLY" = true ]; then
    echo -e "\n${YELLOW}Modalità --test selezionata: Nessuna modifica applicata.${NC}"
    echo -e "Risultati baseline (PRIMA): TPS Base: ${BEFORE_TPS1} | TPS Alto: ${BEFORE_TPS3}"
    exit 0
fi

# ==============================================================================
# FASE 2: APPLICAZIONE TUNING DYNAMIC
# ==============================================================================
echo -e "\n${BLUE}>>> Applicazione impostazioni di Tuning Ottimizzate...${NC}"

if [ -f "$PG_CONF_FILE" ]; then
    sed -i "s/^#*shared_buffers =.*/shared_buffers = ${PG_SHARED_BUFFERS}MB/" "$PG_CONF_FILE"
    sed -i "s/^#*effective_cache_size =.*/effective_cache_size = ${PG_EFFECTIVE_CACHE}MB/" "$PG_CONF_FILE"
    sed -i "s/^#*work_mem =.*/work_mem = ${PG_WORK_MEM}MB/" "$PG_CONF_FILE"
    sed -i "s/^#*maintenance_work_mem =.*/maintenance_work_mem = ${PG_MAINT_WORK_MEM}MB/" "$PG_CONF_FILE"
    sed -i "s/^#*max_connections =.*/max_connections = 200/" "$PG_CONF_FILE"
    
    systemctl restart postgresql
    echo -e "  ${GREEN}✔ PostgreSQL riavviato con successo.${NC}"
fi

if [ -f "$OE_CONFIG" ]; then
    sed -i "s/^#*workers =.*/workers = ${ODOO_WORKERS}/" "$OE_CONFIG"
    sed -i "s/^#*limit_memory_soft =.*/limit_memory_soft = ${LIMIT_MEMORY_SOFT}/" "$OE_CONFIG"
    sed -i "s/^#*limit_memory_hard =.*/limit_memory_hard = ${LIMIT_MEMORY_HARD}/" "$OE_CONFIG"
    
    if systemctl is-active --quiet odoo; then
        systemctl restart odoo
        echo -e "  ${GREEN}✔ Servizio Odoo riavviato con successo.${NC}"
    fi
fi

# ==============================================================================
# FASE 3: BENCHMARK FINALE (DOPO)
# ==============================================================================
run_stress_benchmark "AFTER"

# ==============================================================================
# FASE 4: DASHBOARD COMPARATIVA A VIDEO
# ==============================================================================
calc_diff() {
    local b=$1
    local a=$2
    python3 -c "
try:
    before = float('$b')
    after = float('$a')
    diff = ((after - before) / before) * 100
    if diff > 0:
        print(f'\033[0;32m+{diff:.2f}%\033[0m')
    elif diff < 0:
        print(f'\033[0;31m{diff:.2f}%\033[0m')
    else:
        print('0.00%')
except:
    print('N/A')
"
}

DIFF_TPS1=$(calc_diff "$BEFORE_TPS1" "$AFTER_TPS1")
DIFF_LAT1=$(calc_diff "$AFTER_LAT1" "$BEFORE_LAT1") # Per la latenza, meno è meglio
DIFF_TPS2=$(calc_diff "$BEFORE_TPS2" "$AFTER_TPS2")
DIFF_LAT2=$(calc_diff "$AFTER_LAT2" "$BEFORE_LAT2")
DIFF_TPS3=$(calc_diff "$BEFORE_TPS3" "$AFTER_TPS3")
DIFF_LAT3=$(calc_diff "$AFTER_LAT3" "$BEFORE_LAT3")

echo -e "\n${CYAN}===================================================================================${NC}"
echo -e "${BOLD}                       DASHBOARD COMPARATIVA PRESTAZIONI                           ${NC}"
echo -e "${CYAN}===================================================================================${NC}"
printf "%-25s | %-15s | %-15s | %-15s\n" "METRICA DI CARICO" "PRIMA (ORIGINE)" "DOPO (OTTIMIZZATO)" "VARIAZIONE %"
echo "-----------------------------------------------------------------------------------"
printf "%-25s | %-15s | %-15s | %b\n" "TPS Base (10 Client)" "$BEFORE_TPS1" "$AFTER_TPS1" "$DIFF_TPS1"
printf "%-25s | %-15s | %-15s | %b\n" "Latenza Base (ms)" "${BEFORE_LAT1} ms" "${AFTER_LAT1} ms" "$DIFF_LAT1"
echo "-----------------------------------------------------------------------------------"
printf "%-25s | %-15s | %-15s | %b\n" "TPS Medio (25 Client)" "$BEFORE_TPS2" "$AFTER_TPS2" "$DIFF_TPS2"
printf "%-25s | %-15s | %-15s | %b\n" "Latenza Media (ms)" "${BEFORE_LAT2} ms" "${AFTER_LAT2} ms" "$DIFF_LAT2"
echo "-----------------------------------------------------------------------------------"
printf "%-25s | %-15s | %-15s | %b\n" "TPS Alto (50 Client)" "$BEFORE_TPS3" "$AFTER_TPS3" "$DIFF_TPS3"
printf "%-25s | %-15s | %-15s | %b\n" "Latenza Alta (ms)" "${BEFORE_LAT3} ms" "${AFTER_LAT3} ms" "$DIFF_LAT3"
echo -e "${CYAN}===================================================================================${NC}"

echo -e "\n${BOLD}PARAMETRI DI TUNING APPLICATI:${NC}"
echo -e "  • PostgreSQL Shared Buffers : ${GREEN}${PG_SHARED_BUFFERS} MB${NC}"
echo -e "  • PostgreSQL Effective Cache: ${GREEN}${PG_EFFECTIVE_CACHE} MB${NC}"
echo -e "  • PostgreSQL Work Mem       : ${GREEN}${PG_WORK_MEM} MB${NC}"
echo -e "  • Odoo Worker HTTP Attivi   : ${GREEN}${ODOO_WORKERS}${NC}"
echo -e "${CYAN}===================================================================================${NC}\n"
