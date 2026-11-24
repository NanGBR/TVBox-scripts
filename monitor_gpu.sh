#!/usr/bin/env bash
# Benchmark sequencial da GPU Mali-400 com GLMark2 no Armbian.
# Uso: ./monitor_gpu.sh ambiente | aquecido
# 3 repeticoes por resolucao: 640x480, 800x600 e 1280x720.
# Nao aplica limite nem interrupcao termica automatica.
# O codigo e IDENTICO para as duas campanhas; o nome so rotula pasta e arquivos.

set -u

# Forca ponto decimal e comportamento previsivel do awk (mawk respeita LC_NUMERIC;
# em pt_BR ele escreveria "75,0" e quebraria as colunas do CSV).
export LC_ALL=C
export LANG=C

CAMPANHA="${1:-}"
if [[ "$CAMPANHA" != "ambiente" && "$CAMPANHA" != "aquecido" ]]; then
    echo "Uso: $0 {ambiente|aquecido}"; exit 1
fi
command -v glmark2 >/dev/null 2>&1 || { echo "ERRO: glmark2 nao encontrado."; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUT_DIR="$SCRIPT_DIR/resultados/${CAMPANHA}_${TIMESTAMP}"
mkdir -p "$OUT_DIR" || { echo "ERRO: nao foi possivel criar $OUT_DIR"; exit 1; }
MONITORAMENTO_CSV="$OUT_DIR/monitoramento.csv"
RESULTADOS_CSV="$OUT_DIR/resultados.csv"
GLOBAL_LOG="$OUT_DIR/benchmark.log"
RESUMO_TXT="$OUT_DIR/resumo.txt"

THERMAL_FILE="/sys/class/thermal/thermal_zone0/temp"
CPU_FREQ_FILE="/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq"
CPU_FREQ_FALLBACK="/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq"
GPU_FREQ_FILE="/sys/class/devfreq/20000000.gpu/cur_freq"
# No equipamento: cooling_device0 = GPU; cooling_device1 = CPU.
GPU_COOLING_FILE="/sys/class/thermal/cooling_device0/cur_state"
CPU_COOLING_FILE="/sys/class/thermal/cooling_device1/cur_state"
RESOLUCOES=("640x480" "800x600" "1280x720")
REPETICOES=3

echo "timestamp,run_id,campanha,repeticao,resolucao,temperatura_c,cpu_mhz,gpu_mhz,cpu_cooling,gpu_cooling" > "$MONITORAMENTO_CSV"
echo "run_id,repeticao,resolucao,score,status,temp_media_c,temp_max_c,cpu_media_mhz,gpu_media_mhz" > "$RESULTADOS_CSV"

# Painel em /dev/tty somente se o terminal puder realmente ser aberto.
USAR_TTY=0
if { : > /dev/tty; } 2>/dev/null; then USAR_TTY=1; fi

GLMARK_PID=""
limpar_e_sair() {
    echo; echo "Interrompido. Encerrando glmark2..."
    [[ -n "$GLMARK_PID" ]] && kill "$GLMARK_PID" 2>/dev/null
    exit 130
}
trap limpar_e_sair INT TERM

ler_arquivo() {
    local arquivo="$1"
    if [[ -r "$arquivo" ]]; then tr -d '[:space:]' < "$arquivo" 2>/dev/null; else printf "NA"; fi
}
ler_temperatura() {
    local v; v="$(ler_arquivo "$THERMAL_FILE")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then awk -v v="$v" 'BEGIN{printf "%.1f",v/1000}'; else printf "NA"; fi
}
ler_cpu_mhz() {
    local v; v="$(ler_arquivo "$CPU_FREQ_FILE")"
    [[ "$v" =~ ^[0-9]+$ ]] || v="$(ler_arquivo "$CPU_FREQ_FALLBACK")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then awk -v v="$v" 'BEGIN{printf "%.1f",v/1000}'; else printf "NA"; fi
}
ler_gpu_mhz() {
    local v; v="$(ler_arquivo "$GPU_FREQ_FILE")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then awk -v v="$v" 'BEGIN{printf "%.1f",v/1000000}'; else printf "NA"; fi
}
ler_estado() {
    local v; v="$(ler_arquivo "$1")"
    if [[ "$v" =~ ^[0-9]+$ ]]; then printf "%s" "$v"; else printf "NA"; fi
}

# Saida: media,maximo,minimo,mediana,desvio_padrao,quantidade
estatisticas_temperatura_run() {
    local id="$1"
    awk -F',' -v id="$id" '
    NR>1 && $2==id {
        v=$6; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if(v ~ /^[0-9]+([.][0-9]+)?$/) {
            x=v+0; n++; soma+=x; soma2+=x*x; dados[n]=x
            if(n==1 || x<minimo) minimo=x
            if(n==1 || x>maximo) maximo=x
        }
    }
    END {
        if(n==0){print "NA,NA,NA,NA,NA,0"; exit}
        media=soma/n; variancia=soma2/n-media*media; if(variancia<0) variancia=0
        dp=sqrt(variancia)
        for(i=1;i<=n;i++) for(j=i+1;j<=n;j++) if(dados[i]>dados[j]) {a=dados[i];dados[i]=dados[j];dados[j]=a}
        if(n%2) mediana=dados[(n+1)/2]; else mediana=(dados[n/2]+dados[n/2+1])/2
        printf "%.2f,%.2f,%.2f,%.2f,%.2f,%d\n",media,maximo,minimo,mediana,dp,n
    }' "$MONITORAMENTO_CSV"
}
estatistica_frequencia_run() {
    local id="$1" coluna="$2"
    awk -F',' -v id="$id" -v c="$coluna" '
    NR>1 && $2==id {v=$c;gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);if(v~/^[0-9]+([.][0-9]+)?$/){soma+=v;n++}}
    END{if(n)printf "%.2f\n",soma/n;else print "NA"}' "$MONITORAMENTO_CSV"
}
extrair_score() {
    awk '/glmark2 Score:/ {valor=$NF} END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", valor);if(valor~/^[0-9]+([.][0-9]+)?$/)print valor;else print "NA"}' "$1"
}

executar_benchmark() {
    local repeticao="$1" resolucao="$2" run_id="R${1}_${2}"
    local log="$OUT_DIR/${run_id}.log" inicio fim duracao rc score status stats
    local temp_media temp_max temp_min temp_med temp_dp qtd cpu_media gpu_media
    local timestamp temp cpu gpu cpu_cooling gpu_cooling
    echo; echo "------------------------------------------------------------"
    echo "Iniciando $run_id | campanha=$CAMPANHA | resolucao=$resolucao"
    echo "Log: $log"
    inicio="$(date +%s)"
    glmark2 --size "$resolucao" > "$log" 2>&1 < /dev/null &
    GLMARK_PID=$!
    while :; do
        # Amostra ANTES de testar o processo: garante >= 1 amostra por execucao.
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        temp="$(ler_temperatura)"; cpu="$(ler_cpu_mhz)"; gpu="$(ler_gpu_mhz)"
        cpu_cooling="$(ler_estado "$CPU_COOLING_FILE")"; gpu_cooling="$(ler_estado "$GPU_COOLING_FILE")"
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$timestamp" "$run_id" "$CAMPANHA" "$repeticao" "$resolucao" "$temp" "$cpu" "$gpu" "$cpu_cooling" "$gpu_cooling" >> "$MONITORAMENTO_CSV"
        if (( USAR_TTY )); then
            {
                printf '\033[H\033[2J'
                echo "MONITORAMENTO GLMARK2 - $CAMPANHA"
                echo "Execucao: $run_id | Resolucao: $resolucao"
                echo
                echo "Temperatura SoC: ${temp} C"
                echo "Frequencia CPU:  ${cpu} MHz"
                echo "Frequencia GPU:  ${gpu} MHz"
                echo "Cooling CPU:     $cpu_cooling"
                echo "Cooling GPU:     $gpu_cooling"
                echo
                echo "Benchmark em andamento | amostragem nominal: 1 s"
            } > /dev/tty 2>/dev/null
        fi
        kill -0 "$GLMARK_PID" 2>/dev/null || break
        sleep 1
    done
    wait "$GLMARK_PID"; rc=$?
    GLMARK_PID=""
    fim="$(date +%s)"; duracao=$((fim-inicio))
    score="$(extrair_score "$log")"
    if ((rc==0)) && [[ "$score" != "NA" ]]; then status="OK"
    elif ((rc!=0)); then status="ERRO"; else status="SEM_SCORE"; fi
    if [[ "$status" != "OK" ]]; then
        echo "AVISO: $run_id terminou com status=$status (rc=$rc). Ultimas linhas do log do glmark2:"
        tail -n 5 "$log" | sed 's/^/    /'
    fi
    stats="$(estatisticas_temperatura_run "$run_id")"
    IFS=',' read -r temp_media temp_max temp_min temp_med temp_dp qtd <<< "$stats"
    cpu_media="$(estatistica_frequencia_run "$run_id" 7)"
    gpu_media="$(estatistica_frequencia_run "$run_id" 8)"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$run_id" "$repeticao" "$resolucao" "$score" "$status" "$temp_media" "$temp_max" "$cpu_media" "$gpu_media" >> "$RESULTADOS_CSV"
    {
        echo "Execucao: $run_id"; echo "Codigo de retorno: $rc"; echo "Duracao: ${duracao} segundos"
        echo "Score: $score"; echo "Status: $status"; echo "Temperatura media: $temp_media C"
        echo "Temperatura mediana: $temp_med C"; echo "Temperatura minima: $temp_min C"
        echo "Temperatura maxima: $temp_max C"; echo "Desvio padrao temperatura: $temp_dp C"
        echo "Quantidade de amostras: $qtd"; echo "CPU media: $cpu_media MHz"; echo "GPU media: $gpu_media MHz"; echo
    } >> "$RESUMO_TXT"
    echo "Concluido: $run_id | score=$score | status=$status | duracao=${duracao}s"
    echo "Temperatura: media=${temp_media} C | mediana=${temp_med} C | max=${temp_max} C"
}

estatisticas_scores() {
    echo; echo "=============================================="; echo "       ESTATISTICAS DE PONTUACAO"; echo "=============================================="
    local resolucao
    for resolucao in "${RESOLUCOES[@]}"; do
        awk -F',' -v r="$resolucao" '
        NR>1 && $3==r {
            v=$4;gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if($5=="OK" && v~/^[0-9]+([.][0-9]+)?$/) {
                x=v+0;n++;soma+=x;soma2+=x*x
                if(n==1||x<minimo)minimo=x;if(n==1||x>maximo)maximo=x
            }
        }
        END {
            if(!n){printf "\nResolucao: %s\nSem pontuacoes validas.\n",r;exit}
            media=soma/n;dp=0
            if(n>1){variancia=(soma2-soma*soma/n)/(n-1);if(variancia<0)variancia=0;dp=sqrt(variancia)}
            printf "\nResolucao: %s\nExecucoes validas: %d\nMedia: %.2f\nDesvio padrao amostral: %.2f\nMenor pontuacao: %.2f\nMaior pontuacao: %.2f\n",r,n,media,dp,minimo,maximo
        }' "$RESULTADOS_CSV"
    done
}
estatisticas_temperaturas_finais() {
    echo; echo "=============================================="; echo "       ESTATISTICAS DE TEMPERATURA"; echo "=============================================="
    local run_id repeticao resolucao score status resto
    while IFS=',' read -r run_id repeticao resolucao score status resto; do
        [[ "$run_id" == "run_id" ]] && continue
        local stats media maximo minimo mediana dp qtd
        stats="$(estatisticas_temperatura_run "$run_id")"
        IFS=',' read -r media maximo minimo mediana dp qtd <<< "$stats"
        echo; echo "Execucao: $run_id | resolucao: $resolucao"
        echo "Amostras validas: $qtd"; echo "Media: $media C"; echo "Mediana: $mediana C"
        echo "Desvio padrao populacional: $dp C"; echo "Minima: $minimo C"; echo "Maxima: $maximo C"
    done < "$RESULTADOS_CSV"
}

principal() {
    echo "============================================================"
    echo " BENCHMARK GPU - RK322x / MALI-400 / GLMARK2"
    echo "============================================================"
    echo "Campanha: $CAMPANHA | Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Saida: $OUT_DIR"
    echo "Repeticoes: $REPETICOES | Resolucao: ${RESOLUCOES[*]}"
    echo "Total previsto: $((REPETICOES * ${#RESOLUCOES[@]})) benchmarks"
    echo "Ambiente: usuario=$(id -un) | DISPLAY=${DISPLAY:-<vazio>} | tty=$([[ $USAR_TTY -eq 1 ]] && echo sim || echo nao) | awk=$(readlink -f "$(command -v awk)")"
    echo "============================================================"
    if [[ -z "${DISPLAY:-}" ]]; then
        echo "AVISO: DISPLAY vazio. Se o glmark2 falhar, rode: export DISPLAY=:0"
    fi

    local repeticao resolucao
    for repeticao in $(seq 1 "$REPETICOES"); do
        for resolucao in "${RESOLUCOES[@]}"; do executar_benchmark "$repeticao" "$resolucao"; done
    done

    {
        echo; echo "============================================================"; echo "RELATORIO ESTATISTICO FINAL"
        echo "Campanha: $CAMPANHA"; echo "Inicio: $TIMESTAMP"; echo "Fim: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "============================================================"
    } | tee -a "$RESUMO_TXT"
    estatisticas_scores | tee -a "$RESUMO_TXT"
    estatisticas_temperaturas_finais | tee -a "$RESUMO_TXT"
    echo; echo "Campanha finalizada. Arquivos em: $OUT_DIR"
    echo " - monitoramento.csv"; echo " - resultados.csv"; echo " - benchmark.log"; echo " - resumo.txt"; echo " - logs individuais"
}

# Pipe em vez de exec > >(tee): o shell espera o tee terminar, sem perder o fim do log.
principal 2>&1 | tee -a "$GLOBAL_LOG"
