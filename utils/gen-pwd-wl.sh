#!/bin/bash

# Configurazione
CUSTOMER_LABEL=$1
HOST=$2
OUT_DIR="/tmp/wordlists"
CURRENT_YEAR=$(date +%Y)
LOOKBACK=10

# Controllo input
if [ -z "$CUSTOMER_LABEL" ] || [ -z "$HOST" ]; then
    echo "Usage: $0 <customer_label> <host>" >&2
    exit 1
fi

# --- LOGICA RIMOZIONE TLD ---
# Rimuove l'estensione finale (es. 'dev.acme.it' -> 'dev.acme')
# Se l'host non ha punti (es. un hostname interno), rimane invariato.
HOST_NO_TLD=$(echo "$HOST" | sed 's/\.[^.]*$//')

mkdir -p "$OUT_DIR"
SAFE_HOST=$(echo "$HOST" | tr '.' '_')
FINAL_PATH="${OUT_DIR}/wl_${CUSTOMER_LABEL}_${SAFE_HOST}.txt"

# 1. Estrazione Token con 'tok'
# Usiamo il label e l'host senza TLD
TOKENS=$(echo "$CUSTOMER_LABEL $HOST_NO_TLD" | tok | tr '[:upper:]' '[:lower:]' | sort -u)

# 2. Generazione Wordlist con logica temporale (10 anni)
WORDLIST_CONTENT=$(echo "$TOKENS" | awk -v cur_y="$CURRENT_YEAR" -v lookback="$LOOKBACK" '{
    if (length($0) < 2) next; # Ignora token singoli (es. 'v', 's')

    print $0; # Parola pura

    for (i = 0; i <= lookback; i++) {
        year = cur_y - i;
        
        print $0 year;            # acme2026
        print $0 year "!";        # acme2026!
        
        cap = toupper(substr($0,1,1)) substr($0,2);
        print cap year;           # Acme2026
        print cap year "!";       # Acme2026!
    }
} END {
    # Defaults universali
    print "admin"; print "root"; print "password"; 
    print "admin123"; print "P@ssword!";
}')

# 3. Salvataggio e Deduplicazione
echo "$WORDLIST_CONTENT" | sort -u > "$FINAL_PATH"

# --- OUTPUT ---
# Full list su STDERR per n8n logs
echo "--- DEBUG: WORDLIST (NO TLD) ---" >&2
cat "$FINAL_PATH" >&2
echo "--- END DEBUG ---" >&2

# Path su STDOUT per il modulo successivo
echo "$FINAL_PATH"