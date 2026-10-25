# Odoo Installer
<img alt="image" src="https://github.com/user-attachments/assets/077ae61a-7870-41d0-a792-a628596e1e51" />

![OS](https://img.shields.io/badge/OS-Ubuntu%2022.04%20%7C%2024.04%20%7C%2026.04%20%7C%20Debian%2012%20%7C%2013-blue)
![Odoo](https://img.shields.io/badge/Odoo-8.0%20to%2020.0-purple)
![License](https://img.shields.io/badge/License-MIT-green)

Script per l'installazione, l'aggiornamento e l'ottimizzazione di Odoo Community Edition.

---

## Informazioni su Odoo e l'Ecosistema

**Odoo** è una delle suite di software gestionale (ERP/CRM) open-source più diffuse al mondo, basata su un'architettura modulare in Python e PostgreSQL. Consente di gestire qualsiasi processo aziendale (contabilità, vendite, magazzino, produzione, e-commerce) attraverso moduli integrati.

### Le Associazioni di Riferimento
* **[OCA (Odoo Community Association)](https://odoo-community.org/):** Organizzazione internazionale senza scopo di lucro che promuove ilர்களில் sviluppo collaborativo delle funzionalità di Odoo e supporta la crescita della community globale attraverso la manutenzione di migliaia di repository di moduli testati e indipendenti dal vendor.
* **[Odoo Italia (odoo-italia.org)](https://www.odoo-italia.org/):** L'associazione di riferimento per il mercato italiano. Svolge un lavoro fondamentale di aggregazione della community nazionale, promozione delle normative fiscali italiane (come la fatturazione elettronica e i registri IVA), coordinamento della localizzazione e divulgazione delle best practices per l'adozione di Odoo nelle aziende italiane.

---

## `setup.sh`

Gestisce l'intero ciclo di vita dell'installazione, la sincronizzazione dei moduli e gli aggiornamenti di sistema.

### Funzioni e Logica di Esecuzione
* **Controllo Installazione Esistente (Porta 8069):**
  * Rileva se Odoo è già attivo. In caso positivo, richiede se avviare la procedura di aggiornamento completo.
  * Configura forzatamente l'encoding `UTF-8` (`en_US.UTF-8`), gestisce il fuso orario (`tzdata`) e imposta il layout della tastiera.
  * Interroga le API di GitHub per generare automaticamente o leggere il file `oca.txt`, escludendo i repository di unit test, `openupgrade`, `.github` e `OCB`.
* **Sincronizzazione Moduli e Dipendenze:**
  * Seleziona la versione di Odoo (dalla `8.0` alla `20.0`).
  * Esegue `clone` o `pull` dei repository OCA filtrati per branch, crea automaticamente i link simbolici dei moduli in `custom_addons` e allinea le dipendenze Python leggendo i file `requirements.txt`.
* **Servizi:**
  * Configura l'auto-tuning iniziale per PostgreSQL e Odoo, genera lo script di backup automatizzato (`odoo_backup.sh`), la rotazione dei log (`logrotate`) e il demone `systemd`.
* **Health Check & Collaudo Finale:**
  * Verifica lo stato operativo della porta HTTP (`8069`), risponde ai test sulle API web (`/web/health`, `/web/database/selector`) e convalida l'endpoint JSON-RPC.

---

## `odoo_optimizer.sh`

Script per benchmarking di PostgreSQL e Odoo.

### Funzioni e Logica di Esecuzione
* **Hardware Auto-Tuning Dinamico:**
  * Mappa la RAM e i core CPU (`nproc`) per calcolare e iniettare i parametri ottimali in `postgresql.conf` (`shared_buffers`, `effective_cache_size`, `work_mem`, `maintenance_work_mem`, `max_connections`) e in `odoo.conf` (`workers`).
* **Opzioni CLI di Controllo:**
  * `--test`: Esegue una simulazione (dry-run) generando un report con i consigli di tuning senza modificare alcun file o riavviare i servizi.
  * `--debug`: Attiva il tracciamento atomico e verboso in tempo reale (`set -x`).
  * `--help` / `-h`: Visualizza il manuale d'uso integrato.
* **Benchmark Integrato:**
  * Esegue test transazionali sul database tramite `pgbench` (misurazione delle Transazioni Per Secondo - TPS).
  * Esegue stress test HTTP sulla porta `8069` tramite `ab` (Apache Bench) per verificare la reattività dei worker.
