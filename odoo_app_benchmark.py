#!/usr/bin/env python3
import xmlrpc.client
import time
import concurrent.futures
import statistics
import sys

# ==============================================================================
# CONFIGURAZIONE CONNESSIONE ODOO
# ==============================================================================
URL = "http://127.0.0.1:8069"
DB = "test"               # Nome del tuo database con dati demo
USERNAME = "admin"        # Username o email amministratore
PASSWORD = "tua_password"   # Password admin

# Profili di stress test multi-livello
PROFILES = [
    {"name": "Carico Leggero", "clients": 5, "iterations": 10},
    {"name": "Carico Medio",   "clients": 15, "iterations": 15},
    {"name": "Carico Alto",    "clients": 30, "iterations": 20},
]

def test_worker(clients, iterations):
    latencies = []
    success_count = 0
    error_count = 0

    def single_task():
        nonlocal success_count, error_count
        start_time = time.time()
        try:
            common = xmlrpc.client.ServerProxy(f'{URL}/xmlrpc/2/common')
            uid = common.authenticate(DB, USERNAME, PASSWORD, {})
            if not uid:
                error_count += 1
                return

            models = xmlrpc.client.ServerProxy(f'{URL}/xmlrpc/2/object')

            # 1. Ricerca partner
            partners = models.execute_kw(DB, uid, PASSWORD,
                'res.partner', 'search_read',
                [[['customer_rank', '>', 0]]],
                {'fields': ['name'], 'limit': 3}
            )
            # 2. Ricerca prodotti
            products = models.execute_kw(DB, uid, PASSWORD,
                'product.product', 'search_read',
                [[['sale_ok', '=', True]]],
                {'fields': ['name'], 'limit': 3}
            )

            if products and partners:
                partner_id = partners[0]['id']
                product_id = products[0]['id']
                
                # 3. Creazione e conferma ordine di vendita (Transazione ORM complessa)
                order_id = models.execute_kw(DB, uid, PASSWORD,
                    'sale.order', 'create', [{
                        'partner_id': partner_id,
                        'order_line': [(0, 0, {'product_id': product_id, 'product_uom_qty': 1.0, 'price_unit': 50.0})]
                    }]
                )
                if order_id:
                    models.execute_kw(DB, uid, PASSWORD, 'sale.order', 'action_confirm', [[order_id]])

            elapsed = (time.time() - start_time) * 1000
            latencies.append(elapsed)
            success_count += 1
        except Exception:
            error_count += 1

    start_total = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as executor:
        futures = [executor.submit(single_task) for _ in range(clients * iterations)]
        concurrent.futures.wait(futures)
    total_time = time.time() - start_total

    tps = success_count / total_time if total_time > 0 else 0
    avg_lat = statistics.mean(latencies) if latencies else 0
    p95_lat = statistics.quantiles(latencies, n=20)[18] if len(latencies) >= 20 else (max(latencies) if latencies else 0)

    return success_count, error_count, tps, avg_lat, p95_lat

def main():
    print("=" * 85)
    print("       BENCHMARK APPLICATIVO MULTI-LIVELLO ODOO (XML-RPC/ORM)")
    print("=" * 85)
    print(f"Target URL : {URL} | Database: {DB}\n")

    results = []
    for profile in PROFILES:
        print(f"🔄 Esecuzione test: {profile['name']} ({profile['clients']} client simultanei)...")
        succ, err, tps, avg_lat, p95_lat = test_worker(profile['clients'], profile['iterations'])
        results.append({
            "profile": profile['name'],
            "clients": profile['clients'],
            "success": succ,
            "errors": err,
            "tps": tps,
            "avg_lat": avg_lat,
            "p95_lat": p95_lat
        })

    # ==============================================================================
    # TABELLA COMPARATIVA FINALE
    # ==============================================================================
    print("\n" + "=" * 85)
    print("                       DASHBOARD COMPARATIVA DEI TEST")
    print("=" * 85)
    print(f"{'Profilo Carico':<18} | {'Client':<6} | {'Successi':<8} | {'TPS':<8} | {'Latenza Media':<15} | {'P95 Latenza':<15}")
    print("-" * 85)
    for r in results:
        print(f"{r['profile']:<18} | {r['clients']:<6} | {r['success']:<8} | {r['tps']:<8.2f} | {r['avg_lat']:<13.2f} ms | {r['p95_lat']:<13.2f} ms")
    print("=" * 85)

    # ==============================================================================
    # ANALISI E RACCOMANDAZIONI AUTOMATICHE
    # ==============================================================================
    print("\n🔍 ANALISI E SUGGERIMENTI DI OTTIMIZZAZIONE:")
    high_load = results[-1] # Prende come riferimento il carico più alto

    if high_load['errors'] > 0:
        print(f"  • ⚠️  **Errori rilevati ({high_load['errors']} fallimenti):** Aumenta il parametro `max_connections` in PostgreSQL o verifica i limiti di memoria (`limit_memory_soft/hard`) nel file `/etc/odoo.conf`.")
    else:
        print("  • ✅ **Stabilità ottimale:** Nessun errore riscontrato neanche sotto stress elevato.")

    if high_load['avg_lat'] > 1000:
        print(f"  • ⚠️  **Latenza elevata ({high_load['avg_lat']:.2f} ms):** Il tempo di risposta sotto carico supera 1 secondo. Valuta di aumentare il numero di `workers` in `/etc/odoo.conf` o di allocare più RAM a PostgreSQL (`shared_buffers`).")
    else:
        print("  • ✅ **Tempi di risposta eccellenti:** La latenza media rimane entro soglie ottimali per transazioni ORM complesse.")

    if high_load['tps'] < 10:
        print(f"  • ⚠️  **Throughput basso ({high_load['tps']:.2f} TPS):** Il server fatica a smaltire le richieste in parallelo. Ottimizza i dischi (usa NVMe) o rivedi i parametri di cache di PostgreSQL.")
    else:
        print(f"  • ✅ **Throughput solido ({high_load['tps']:.2f} TPS):** Ottima capacità di elaborazione simultanea delle richieste di business logic.")
    print("=" * 85)

if __name__ == "__main__":
    main()
