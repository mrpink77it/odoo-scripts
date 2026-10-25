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
DB = "il_tuo_database_demo"  # Sostituisci con il nome del tuo DB con dati demo
USERNAME = "admin"          # Email o username amministratore
PASSWORD = "tua_password"     # Password admin

# Parametri del test di carico
NUM_CLIENTS = 10     # Numero di thread concorrenti simultanei
ITERATIONS = 20      # Numero di cicli di transazioni per ogni client

def test_odoo_transaction(client_id):
    """Esegue una sequenza tipica di transazioni di business su Odoo"""
    latencies = []
    success_count = 0
    error_count = 0

    try:
        common = xmlrpc.client.ServerProxy(f'{URL}/xmlrpc/2/common')
        uid = common.authenticate(DB, USERNAME, PASSWORD, {})
        if not uid:
            return 0, 0, [0]

        models = xmlrpc.client.ServerProxy(f'{URL}/xmlrpc/2/object')

        for i in range(ITERATIONS):
            start_time = time.time()
            try:
                # 1. Ricerca partner (Clienti/Fornitori)
                partners = models.execute_kw(DB, uid, PASSWORD,
                    'res.partner', 'search_read',
                    [[['customer_rank', '>', 0]]],
                    {'fields': ['name', 'email'], 'limit': 5}
                )

                # 2. Ricerca prodotti attivi nei dati demo
                products = models.execute_kw(DB, uid, PASSWORD,
                    'product.product', 'search_read',
                    [[['sale_ok', '=', True]]],
                    {'fields': ['name', 'list_price'], 'limit': 5}
                )

                if products and partners:
                    partner_id = partners[0]['id']
                    product_id = products[0]['id']

                    # 3. Transazione complessa: Creazione di un Preventivo/Ordine di Vendita (Sale Order)
                    # Questo attiva la business logic ORM di Odoo (calcolo prezzi, tasse, righe)
                    order_id = models.execute_kw(DB, uid, PASSWORD,
                        'sale.order', 'create', [{
                            'partner_id': partner_id,
                            'order_line': [
                                (0, 0, {
                                    'product_id': product_id,
                                    'product_uom_qty': 2.0,
                                    'price_unit': 100.0,
                                })
                            ]
                        }]
                    )

                    # 4. Conferma dell'ordine (transazione di stato)
                    if order_id:
                        models.execute_kw(DB, uid, PASSWORD,
                            'sale.order', 'action_confirm', [[order_id]]
                        )

                elapsed = (time.time() - start_time) * 1000  # in millisecondi
                latencies.append(elapsed)
                success_count += 1
            except Exception as e:
                error_count += 1
                # In caso di errore di transazione registriamo un tempo anomalo o saltiamo
                pass

    except Exception as e:
        print(f"Client {client_id} errore di connessione: {e}")

    return success_count, error_count, latencies

def run_benchmark():
    print("=" * 70)
    print("       ODOO APPLICATION-LEVEL TRANSACTION BENCHMARK (XML-RPC/ORM)")
    print("=" * 70)
    print(f"Target URL : {URL}")
    print(f"Database   : {DB}")
    print(f"Concorrenza: {NUM_CLIENTS} client simultanei")
    print(f"Iterazioni : {ITERATIONS} cicli per client ({NUM_CLIENTS * ITERATIONS} transazioni totali)")
    print("-" * 70)
    print("Esecuzione transazioni in corso (creazione preventivi e ordini reali)...")

    start_total = time.time()
    
    total_success = 0
    total_errors = 0
    all_latencies = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=NUM_CLIENTS) as executor:
        futures = [executor.submit(test_odoo_transaction, i) for i in range(NUM_CLIENTS)]
        for future in concurrent.futures.as_completed(futures):
            succ, err, lats = future.result()
            total_success += succ
            total_errors += err
            all_latencies.extend(lats)

    total_time = time.time() - start_total

    if not all_latencies:
        print("\n❌ Errore: Nessuna transazione completata. Verifica credenziali e nome database.")
        sys.exit(1)

    tps = total_success / total_time
    avg_latency = statistics.mean(all_latencies)
    p95_latency = statistics.quantiles(all_latencies, n=20)[18] if len(all_latencies) > 20 else max(all_latencies)

    print("=" * 70)
    print("                 RISULTATI BENCHMARK APPLICATIVO ODOO")
    print("=" * 70)
    print(f" Transazioni completate con successo : {total_success}")
    print(f" Transazioni fallite / errori      : {total_errors}")
    print(f" Tempo totale di esecuzione        : {total_time:.2f} secondi")
    print(f" Throughput applicativo (TPS)      : {tps:.2f} transazioni/sec")
    print(f" Latenza media per transazione     : {avg_latency:.2f} ms")
    print(f" Latenza al 95° percentile (P95)   : {p95_latency:.2f} ms")
    print("=" * 70)

if __name__ == "__main__":
    run_benchmark()
