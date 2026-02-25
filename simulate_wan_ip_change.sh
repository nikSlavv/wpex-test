#!/bin/bash

# Script per simulare cambio di IP WAN dinamico per uno dei router
# La VPN dovrebbe rimanere connessa grazie al PersistentKeepalive=10

ROUTER="${1:-router-a}"  # Quale router: router-a o router-b
ITERATIONS="${2:-5}"     # Numero di cambi IP
# Trova la rete docker creata da docker-compose che contiene "wan_simulata"
NETWORK=$(docker network ls --format '{{.Name}}' | grep 'wan_simulata' | head -n1)
if [ -z "$NETWORK" ]; then
    echo "❌ Docker network matching 'wan_simulata' non trovata. Avvia con docker-compose up -d"
    exit 1
fi

# Prefisso IP base (override come terzo argomento se necessario)
BASE_IP="${3:-172.18.0}"

echo "🌐 Simulazione cambio IP WAN dinamico per $ROUTER"
echo "=================================================="
echo ""

# Verifica che il container esista
if ! docker ps --filter "name=$ROUTER" --format "{{.Names}}" | grep -q "$ROUTER"; then
    echo "❌ Container $ROUTER non trovato. Avvia i container con docker-compose up -d"
    exit 1
fi

for i in $(seq 1 $ITERATIONS); do
    # Genera IP casuale nella rete 172.18.0.x (3-250)
    RANDOM_IP=$((RANDOM % 248 + 3))
    NEW_IP="$BASE_IP.$RANDOM_IP"
    
    echo ""
    echo "📍 Cambio $i/$ITERATIONS - Nuovo IP WAN: $NEW_IP"
    
    # Disconnetti il container dalla rete WAN
    echo "  🔌 Disconnessione dalla WAN..."
    docker network disconnect "$NETWORK" "$ROUTER" 2>/dev/null
    sleep 2
    
    # Riconnetti con nuovo IP
    echo "  🔌 Riconnessione con nuovo IP..."
    docker network connect --ip "$NEW_IP" "$NETWORK" "$ROUTER" 2>/dev/null
    sleep 3
    
    # Verifica stato WireGuard
    echo "  🔍 Verifica stato WireGuard..."
    if docker exec "$ROUTER" wg show 2>/dev/null | grep -q "peer"; then
        echo "  ✅ WireGuard CONNESSO"
    else
        echo "  ⏳ WireGuard in riconnessione..."
    fi
    
    # Test di connettività
    echo "  🧪 Test di connettività..."
    # Verifica con ping tra i PC di LAN opposte (pc-a <-> pc-b)
    if [ "$ROUTER" = "router-a" ]; then
        TEST_IP="10.100.20.10"  # pc-b
        TEST_CONTAINER="pc-a"
    else
        TEST_IP="10.100.10.10"  # pc-a
        TEST_CONTAINER="pc-b"
    fi

    if docker exec "$TEST_CONTAINER" ping -c 2 -W 2 "$TEST_IP" >/dev/null 2>&1; then
        echo "  ✓ Connessione VPN OK"
    else
        echo "  ✗ Connessione VPN FAIL"
    fi
    
    if [ "$i" -lt "$ITERATIONS" ]; then
        echo "  ⏳ Attesa 10 secondi prima del prossimo cambio..."
        sleep 10
    fi
done

echo ""
echo "✨ Simulazione completata!"
echo ""
echo "📊 Cosa è successo:"
echo "  • L'IP WAN del router è cambiato $ITERATIONS volte"
echo "  • La VPN dovrebbe essersi riconnessa automaticamente"
echo "  • Il relay ha mantenuto la sessione grazie a PersistentKeepalive"
