# Sostituisci la parte del blocco Python nella funzione select_repos_for_installer con questa:

python3 - << 'EOF'
import csv
import os
import sys

repos_csv = "./oca_data/oca_repositories_summary.csv"
output_file = "./oca_data/selected_repos_v18.0.txt" # (o variabile dinamica)
target_ver = "18.0"

repos = []
with open(repos_csv, 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        repos.append(row['repo_name'])

repos = sorted(list(set(repos)))

DEPENDENCIES = {
    "l10n-italy": ["server-tools", "account-financial-reporting", "account-payment", "partner-contact"],
    "account-financial-reporting": ["server-tools", "account-financial-tools"],
    "sale-workflow": ["server-tools", "partner-contact"],
    "purchase-workflow": ["server-tools", "partner-contact"],
    "stock-logistics-workflow": ["server-tools", "product-attribute"],
    "account-asset": ["server-tools", "account-financial-tools"]
}

selected_set = {"l10n-italy"}

def print_menu():
    os.system('clear' if os.name == 'posix' else 'cls')
    print("=" * 75)
    print(f"       SELEZIONE REPOSITORY PER INSTALLER")
    print("=" * 75)
    print(f"📦 Repository attualmente selezionati: {len(selected_set)}")
    print("-" * 75)
    print("  ID   [Stato]   Nome Repository")
    print("-" * 75)
    
    for idx, repo in enumerate(repos, 1):
        status = "[X]" if repo in selected_set else "[ ]"
        print(f" {idx:3d})  {status}    {repo}")
        
    print("-" * 75)
    print(" COMANDI:")
    print("   • Inserisci i numeri separati da spazio (es. 1 5 12)")
    print("   • [A] Seleziona Tutti  |  [R] Reset  |  [O] Conferma (OK)  |  [B] Indietro")
    print("=" * 75)

# Apre direttamente il terminale interattivo per l'input
tty = open('/dev/tty', 'r')
sys.stdin = tty

while True:
    print_menu()
    try:
        choice = input("\nInserisci scelta o comando: ").strip()
    except EOFError:
        break
    
    if choice.upper() == 'O':
        selected_set.add("l10n-italy")
        with open(output_file, 'w', encoding='utf-8') as f:
            for repo in sorted(list(selected_set)):
                f.write(f"{repo}\n")
        print(f"\n✅ Configurazione salvata in '{output_file}' con {len(selected_set)} repository.")
        input("\nPremi INVIO per tornare al menu principale...")
        break
    elif choice.upper() == 'B':
        print("\n↩️ Annullato. Ritorno al menu principale.")
        break
    elif choice.upper() == 'R':
        selected_set = {"l10n-italy"}
        print("\n🔄 Selezione resettata (mantenuto l10n-italy di default).")
        input("Premi INVIO per continuare...")
    elif choice.upper() == 'A':
        selected_set = set(repos)
        print("\n✅ Selezionati tutti i repository.")
        input("Premi INVIO per continuare...")
    else:
        parts = choice.split()
        added_deps = set()
        for p in parts:
            if p.isdigit():
                idx = int(p) - 1
                if 0 <= idx < len(repos):
                    repo = repos[idx]
                    if repo in selected_set:
                        selected_set.remove(repo)
                    else:
                        selected_set.add(repo)
                        if repo in DEPENDENCIES:
                            for dep in DEPENDENCIES[repo]:
                                if dep in repos and dep not in selected_set:
                                    selected_set.add(dep)
                                    added_deps.add(dep)
        if added_deps:
            print(f"\n🔗 Dipendenze aggiunte automaticamente: {', '.join(added_deps)}")
            input("Premi INVIO per continuare...")
EOF
