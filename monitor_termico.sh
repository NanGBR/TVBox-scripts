#!/bin/bash

ARQUIVO="$HOME/termico_$(date +%Y%m%d_%H%M%S).csv"
LOG_STRESS="$HOME/stress_$(date +%Y%m%d_%H%M%S).log"

THERMAL="/sys/class/thermal/thermal_zone0"
CPUFREQ="/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq"
COOLING="/sys/class/thermal/cooling_device1/cur_state"

# ---------------------------------------------------------
# Função para ler estado atual
# ---------------------------------------------------------

ler_estado() {
    HORA=$(date '+%H:%M:%S')

    TEMP=$(awk '{printf "%.1f", $1/1000}' \
        "$THERMAL/temp")

    FREQ=$(cat "$CPUFREQ" 2>/dev/null)

    if [ -n "$FREQ" ]; then
        FREQ=$(awk -v f="$FREQ" 'BEGIN {printf "%.0f", f/1000}')
    else
        FREQ="N/A"
    fi

    STATE=$(cat "$COOLING" 2>/dev/null)

    if [ -z "$STATE" ]; then
        STATE="N/A"
    fi
}

# ---------------------------------------------------------
# Função para escrever uma linha no CSV
# ---------------------------------------------------------

csv() {
    echo "$1" >> "$ARQUIVO"
}

# ---------------------------------------------------------
# Função para executar sysbench
# ---------------------------------------------------------

executar_sysbench() {

    TITULO="$1"

    echo
    echo "=========================================="
    echo " $TITULO"
    echo "=========================================="

    csv ""
    csv "SYSBENCH,$TITULO"
    csv "resultado"

    RESULTADO=$(sysbench cpu \
        --cpu-max-prime=20000 \
        --num-threads=4 \
        run 2>&1)

    # Mostrar TODO o resultado no terminal
    echo "$RESULTADO"

    # Gravar TODO o resultado no CSV
    while IFS= read -r LINHA; do
        csv "\"$LINHA\""
    done <<< "$RESULTADO"

    # Extrair os valores
    EVENTS=$(echo "$RESULTADO" |
        awk -F: 'tolower($1) ~ /events per second/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
        }')

    TOTAL=$(echo "$RESULTADO" |
        awk -F: 'tolower($1) ~ /total number of events/ {
            gsub(/^[ \t]+/, "", $2)
            print $2
        }')

    echo
    echo "Events per second: ${EVENTS:-N/A}"
    echo "Total number of events: ${TOTAL:-N/A}"

    csv "Events per second,\"${EVENTS:-N/A}\""
    csv "Total number of events,\"${TOTAL:-N/A}\""

    echo
}

# ---------------------------------------------------------
# Cabeçalho
# ---------------------------------------------------------

echo "=========================================="
echo "       TESTE TERMICO AUTOMATIZADO"
echo "=========================================="
echo
echo "CSV: $ARQUIVO"
echo "Log stress-ng: $LOG_STRESS"
echo

csv "tipo,timestamp,temperatura_C,freq_MHz,thermal_state"
csv "INICIO,$(date '+%H:%M:%S'),,,"

# ---------------------------------------------------------
# Estado inicial
# ---------------------------------------------------------

ler_estado

echo "Estado inicial:"
echo "Timestamp:   $HORA"
echo "Temperatura: $TEMP °C"
echo "Frequência:  $FREQ MHz"
echo "Estado:      $STATE"

csv "IDLE,$HORA,$TEMP,$FREQ,$STATE"

# ---------------------------------------------------------
# Primeiro Sysbench
# ---------------------------------------------------------

executar_sysbench "BENCHMARK ANTES DO STRESS"

# ---------------------------------------------------------
# Iniciar stress-ng
# ---------------------------------------------------------

echo "=========================================="
echo " INICIANDO STRESS-NG"
echo "=========================================="
echo
echo "Comando:"
echo "sudo stress-ng --cpu 4 --cpu-method all --timeout 10m"
echo

csv ""
csv "STRESS-NG,INICIO,$(date '+%H:%M:%S'),,,"

# Executa stress-ng em segundo plano
sudo stress-ng \
    --cpu 4 \
    --cpu-method all \
    --timeout 10m \
    > "$LOG_STRESS" 2>&1 &

STRESS_PID=$!

echo "PID do stress-ng: $STRESS_PID"
echo

csv "STRESS-NG,PID,$STRESS_PID,,,"

# ---------------------------------------------------------
# Monitoramento
# ---------------------------------------------------------

echo "Monitorando..."
echo

while kill -0 "$STRESS_PID" 2>/dev/null; do

    ler_estado

    # Terminal
    printf "\r%s | %5s °C | %4s MHz | estado %s" \
        "$HORA" "$TEMP" "$FREQ" "$STATE"

    # CSV
    csv "STRESS,$HORA,$TEMP,$FREQ,$STATE"

    sleep 1
done

echo
echo
echo "stress-ng terminou."

wait "$STRESS_PID"
STRESS_EXIT=$?

echo "Código de saída do stress-ng: $STRESS_EXIT"

csv "STRESS-NG,FIM,$(date '+%H:%M:%S'),,,"
csv "STRESS-NG,EXIT_CODE,$STRESS_EXIT,,,"

# ---------------------------------------------------------
# Resultado do stress-ng
# ---------------------------------------------------------

echo
echo "=========================================="
echo " LOG DO STRESS-NG"
echo "=========================================="

cat "$LOG_STRESS"

csv ""
csv "LOG STRESS-NG"

while IFS= read -r LINHA; do
    csv "\"$LINHA\""
done < "$LOG_STRESS"

# ---------------------------------------------------------
# Sysbench final
# ---------------------------------------------------------

executar_sysbench "BENCHMARK DEPOIS DO STRESS"

# ---------------------------------------------------------
# Estado final
# ---------------------------------------------------------

ler_estado

echo "=========================================="
echo " ESTADO FINAL"
echo "=========================================="
echo
echo "Timestamp:   $HORA"
echo "Temperatura: $TEMP °C"
echo "Frequência:  $FREQ MHz"
echo "Estado:      $STATE"

csv ""
csv "FINAL,$HORA,$TEMP,$FREQ,$STATE"

# ---------------------------------------------------------
# Final
# ---------------------------------------------------------

echo
echo "=========================================="
echo " TESTE CONCLUÍDO"
echo "=========================================="
echo
echo "CSV:"
echo "$ARQUIVO"
echo
echo "Log do stress-ng:"
echo "$LOG_STRESS"
echo

csv ""
csv "TESTE CONCLUIDO,$(date '+%H:%M:%S'),,,"
