# Odoo & OCA Deployer

![OS](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian-blue)
![Odoo](https://img.shields.io/badge/Odoo-15.0%20%7C%2016.0%20%7C%2017.0%20%7C%2018.0-purple)
![License](https://img.shields.io/badge/License-MIT-green)

Uno script di automazione Bash interattivo per l'installazione e l'ottimizzazione in produzione di **Odoo ERP** e dei moduli **OCA (Odoo Community Association)** su server Linux bare-metal. 

Questo tool è progettato specificamente per infrastrutture di produzione dove le prestazioni hardware native, la stabilità dei servizi di sistema (`systemd`) e l'ottimizzazione del database sono preferite rispetto agli approcci containerizzati.

## ✨ Caratteristiche Principali

* 🖥️ **Hardware Auto-Tuning:** Calcola dinamicamente le risorse del server (CPU, RAM) per ottimizzare i parametri di PostgreSQL (`shared_buffers`, `effective_cache_size`) e i `workers` di Odoo.
* 📦 **Gestione Selettiva OCA:** Permette di scegliere se scaricare solo i moduli OCA più utilizzati o l'intero ecosistema, riducendo drasticamente i tempi di clone e l'uso del disco.
* 🇮🇹 **Localizzazione Smart:** Modulo `l10n-italy` incluso di default, con possibilità di aggiungere altre localizzazioni internazionali in modo interattivo.
* 🛡️ **Hardening per la Produzione:** Generazione automatica di script per i backup, rotazione dei log (Logrotate) e configurazione per Reverse Proxy.
* 🌐 **Nginx Proxy Manager Ready:** Genera una guida locale con i parametri esatti per l'esposizione sicura tramite NPM (Websockets, Longpolling, Timeout).

---

## 🚀 Requisiti

* **Sistema Operativo:** Ubuntu 22.04/24.04 LTS o Debian 12/13.
* **Privilegi:** Accesso di `root` o utente con privilegi `sudo`.
* **Risorse Minime:** 2 CPU Cores, 2GB RAM (Consigliati: 4+ CPU, 8GB+ RAM per ambienti di produzione).

---

## 🛠️ Utilizzo

1. Clona il repository o scarica lo script sul tuo server:
   ```bash
   git clone [https://github.com/tuo-utente/odoo-oca-deployer.git](https://github.com/tuo-utente/odoo-oca-deployer.git)
   cd odoo-oca-deployer
   ```

2. Rendi lo script eseguibile:
   ```bash
   chmod +x odoo_setup.sh
   ```

3. Esegui l'installer con i privilegi di root:
   ```bash
   sudo ./odoo_setup.sh
   ```

4. Segui le istruzioni a schermo per selezionare la versione di Odoo e i repository OCA desiderati.

---

## 🧠 Logica di Funzionamento (Sotto il cofano)

Lo script non si limita a installare i pacchetti, ma orchestra l'intero ambiente seguendo una logica in 6 fasi:

### 1. Interazione e Scelta Architettura
Lo script interroga l'operatore tramite un'interfaccia a menu per definire il target della build:
* Rileva la versione di Odoo desiderata (15.0 - 18.0).
* Definisce il footprint dell'installazione OCA (Standard "Core" vs Full).
* Inietta le dipendenze di localizzazione specifiche (`l10n-italy` forzata come base).

### 2. Auto-Tuning delle Risorse
Tramite i comandi `free -m` e `nproc`, lo script mappa l'hardware fisico del server. 
* Alloca il 25% della RAM totale a `shared_buffers` e il 75% a `effective_cache_size` per PostgreSQL.
* Calcola il numero aureo dei *workers* di Odoo con la formula `(CPU Cores * 2) + 1` per bilanciare il carico HTTP e i job asincroni senza creare colli di bottiglia nel multiprocessing.

### 3. Preparazione OS e Database
* Forza la disabilitazione dei prompt interattivi di APT (`DEBIAN_FRONTEND=noninteractive`).
* Installa dipendenze di compilazione (build-essential, librerie dev) e tool di rendering (wkhtmltopdf).
* Genera la configurazione `locale` in `en_US.UTF-8` per prevenire crash nell'elaborazione di stringhe in Odoo.
* Crea un utente di sistema isolato (`odoo`) e il relativo ruolo in PostgreSQL.

### 4. Git Clone e Virtual Environment (VENV)
Odoo non viene installato globalmente. Lo script genera un ambiente virtuale Python isolato (`/opt/odoo/venv`) per evitare conflitti con i pacchetti di sistema (PEP 668 compliance). Successivamente, clona il core di Odoo e crea link simbolici per i moduli OCA verso la directory `custom_addons`.

### 5. Deployment dei Servizi di Manutenzione
Per garantire la stabilità a lungo termine, lo script scrive direttamente sul filesystem tre componenti fondamentali:
* **`odoo.service`**: Demone Systemd per il controllo del ciclo di vita dell'applicazione.
* **`logrotate.d/odoo`**: Regola per comprimere i log giornalmente e trattenerli per 14 giorni.
* **`odoo_backup.sh`**: Script bash che esegue il `pg_dump` strutturato e il `tar` del filestore, implementando una *retention policy* automatica di 7 giorni.

### 6. Configurazione Reverse Proxy
Lo script imposta `proxy_mode = True` in `odoo.conf` e rilascia un file in `/opt/guida_npm_odoo.txt`. Questa guida contiene gli header Nginx (`X-Forwarded-For`, `Upgrade`) e i parametri di timeout necessari per gestire i Websocket (porta 8072) ed evitare errori `504 Gateway Timeout` durante la generazione di report PDF massivi.

---

## 📂 Struttura delle Directory Generata

```text
/opt/
 ├── odoo/
 │    ├── odoo-server/       # Core Odoo clonata da GitHub
 │    ├── odoo_repos/        # Repository completi OCA
 │    ├── custom_addons/     # Link simbolici dei moduli OCA (pulizia)
 │    └── venv/              # Ambiente Virtuale Python
 ├── scripts/
 │    └── odoo_backup.sh     # Script di backup automatizzato
 └── guida_npm_odoo.txt      # Parametri Nginx Proxy Manager
```


---
## 🤝 Contribuire

Sentiti libero di aprire Issue o inviare Pull Request per migliorare il tuning hardware o aggiungere nuovi set di repository OCA raccomandati.

## 📄 Licenza

Distribuito sotto licenza MIT. Vedi `LICENSE` per maggiori informazioni.
