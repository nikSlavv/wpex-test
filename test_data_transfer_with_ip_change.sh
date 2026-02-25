#!/bin/bash

# Script per testare il trasferimento dati durante cambio IP WAN dinamico
# Misura cosa succede alla connessione VPN quando l'IP cambia

ROUTER="${1:-router-a}"
DATA_SIZE="${2:-100M}"  # Dimensione dati: 100M, 500M, 1G, etc.
# Trova la rete docker creata da docker-compose che contiene "wan_simulata"
NETWORK=$(docker network ls --format '{{.Name}}' | grep 'wan_simulata' | head -n1)
if [ -z "$NETWORK" ]; then
    echo "❌ Docker network matching 'wan_simulata' non trovata. Avvia con docker-compose up -d"
    exit 1
fi
BASE_IP="${3:-172.18.0}"

# Determina il container di destinazione
if [ "$ROUTER" = "router-a" ]; then
    SOURCE_PC="pc-a"
    DEST_PC="pc-b"
    DEST_IP="10.100.20.10"
else
    SOURCE_PC="pc-b"
    DEST_PC="pc-a"
    DEST_IP="10.100.10.10"
fi

echo "=====================================================
🚀 TEST TRASFERIMENTO DATI + CAMBIO IP WAN
====================================================="
echo ""
echo "📊 Configurazione:"
echo "   Source: $SOURCE_PC"
echo "   Dest: $DEST_PC ($DEST_IP)"
echo "   Data size: $DATA_SIZE"
echo "   Router che cambierà IP: $ROUTER"
echo ""

# Verifica container
if ! docker ps | grep -q "$SOURCE_PC"; then
    echo "❌ Container non trovati. Avvia con: docker-compose up -d"
    exit 1
fi

# Fase 1: Avvia listener su pc-b (installa nc se necessario)
echo "📡 Fase 1: Avvio listener su $DEST_PC (porta 9999)..."
docker exec "$DEST_PC" sh -c 'apk add --no-cache netcat-openbsd >/dev/null 2>&1 || true'
docker exec -d "$DEST_PC" sh -c 'nc -l -p 9999 > /tmp/received_data' 2>/dev/null || true
sleep 2

echo "📤 Fase 2: Inizio trasferimento $DATA_SIZE da $SOURCE_PC a $DEST_IP:9999..."
# Fase 2: Avvia trasferimento dati in background (installa nc se necessario)
echo "📤 Fase 2: Inizio trasferimento $DATA_SIZE da $SOURCE_PC a $DEST_IP:9999..."
TRANSFER_START=$(date +%s)

# Calcola size in MB (supporta M e G)
if echo "$DATA_SIZE" | grep -q -E '^[0-9]+G$'; then
    g=$(echo "$DATA_SIZE" | sed -E 's/([0-9]+)G/\1/')
    SIZE_MB=$((g * 1024))
elif echo "$DATA_SIZE" | grep -q -E '^[0-9]+M$'; then
    SIZE_MB=$(echo "$DATA_SIZE" | sed -E 's/([0-9]+)M/\1/')
else
    SIZE_MB=100
fi

docker exec "$SOURCE_PC" sh -c 'apk add --no-cache netcat-openbsd >/dev/null 2>&1 || true'
docker exec -d "$SOURCE_PC" sh -c "dd if=/dev/urandom bs=1M count=$SIZE_MB 2>/dev/null | nc $DEST_IP 9999" 2>/dev/null || true

# Piccola attesa per far iniziare il trasferimento
sleep 3

# Fase 3: Monitora il trasferimento e cambia IP dopo 5 secondi
echo "⏱️  Fase 3: Monitoraggio trasferimento (cambio IP dopo 5 secondi)..."
sleep 5

echo ""
echo "🔄 CAMBIO IP WAN IN CORSO..."
echo "  🔌 Disconnessione dalla WAN..."
docker network disconnect "$NETWORK" "$ROUTER" 2>/dev/null
sleep 1

RANDOM_IP=$((RANDOM % 248 + 3))
NEW_IP="$BASE_IP.$RANDOM_IP"
echo "  🔌 Riconnessione con nuovo IP: $NEW_IP..."
docker network connect --ip "$NEW_IP" "$NETWORK" "$ROUTER" 2>/dev/null
sleep 2

echo "  ℹ️  Nuovo IP WAN di $ROUTER: $NEW_IP"
echo ""

# Fase 4: Monitora lo stato della connessione
echo "📊 Fase 4: Monitoraggio stato VPN..."
for i in {1..30}; do
    echo ""
    echo "  ▶️ Controllo $i/30..."
    
    # Verifica WireGuard
    WG_STATUS=$(docker exec "$ROUTER" wg show 2>/dev/null | grep -c "peer")
    if [ "$WG_STATUS" -gt 0 ]; then
        echo "  ✅ WireGuard: CONNESSO"
    else
        echo "  ⏳ WireGuard: riconnessione in corso..."
    fi
    
    # Verifica ping
    if docker exec "$SOURCE_PC" ping -c 1 -W 2 "$DEST_IP" >/dev/null 2>&1; then
        echo "  ✅ Ping: OK"
    else
        echo "  ❌ Ping: FALLITO"
    fi
    
    # Verifica se il processo di trasferimento è ancora attivo dentro il container sorgente
    if docker exec "$SOURCE_PC" sh -c "ps aux | grep -E 'dd if=/dev/urandom|nc ' | grep -v grep" >/dev/null 2>&1; then
        echo "  ✅ Trasferimento: IN CORSO"
    else
        echo "  ✅ Trasferimento: COMPLETATO"
        break
    fi
    
    sleep 2
done

TRANSFER_END=$(date +%s)
ELAPSED=$((TRANSFER_END - TRANSFER_START))

echo ""
echo "=====================================================
📈 RISULTATI
====================================================="
echo ""
echo "⏱️  Tempo totale: ${ELAPSED}s"
echo ""

# Verifica file ricevuto
RECEIVED_SIZE=$(docker exec "$DEST_PC" sh -c "[ -f /tmp/received_data ] && ls -lh /tmp/received_data | awk '{print \$5}' || true")
if [ -n "$RECEIVED_SIZE" ]; then
    echo "✅ Dati ricevuti: $RECEIVED_SIZE"
    echo "✅ Trasferimento COMPLETATO durante cambio IP (o parzialmente ricevuto)."
else
    echo "⚠️  Nessun dato ricevuto o trasferimento interrotto"
fi

echo ""
echo "🎯 Test completato!"
echo ""
echo "💡 Interpretazione:"
echo "   • Se il trasferimento continua = VPN stabile con PersistentKeepalive"
echo "   • Se il trasferimento si blocca = Problemi di riconnessione"
echo "   • Se il trasferimento riprende = Riconnessione automatica"
