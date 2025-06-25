#!/bin/bash

# Configuration
IPERF_SERVER="10.45.0.1"
UE_IPS=("10.45.0.12" "10.45.0.13" "10.45.0.14" "10.45.0.15" "10.45.0.16" 
        "10.45.0.17" "10.45.0.18" "10.45.0.19" "10.45.0.20" "10.45.0.21")
UE_PORTS=(5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5211)
UE_COUNT=${#UE_IPS[@]}
TEST_DURATION=100
BANDWIDTH_VALUES=("5G" "10G" "15G" "20G" "25G" "30G" "35G" "40G")

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="tcp_test_results_$TIMESTAMP"

mkdir -p "$OUTPUT_DIR/throughput"
mkdir -p "$OUTPUT_DIR/power"

# Start iperf3 servers
start_iperf_servers() {
    echo "[INFO] Starting iperf3 servers..."
    for port in "${UE_PORTS[@]}"; do
        iperf3 -s -p $port -D &> /dev/null
    done
    sleep 2
    echo "[INFO] iperf3 servers ready."
}

# Stop all iperf3 servers
stop_iperf_servers() {
    echo "[INFO] Stopping iperf3 servers..."
    pkill iperf3
    echo "[INFO] iperf3 servers stopped."
}

# Run test for one UE (called in parallel)
run_test_for_ue() {
    local bw=$1
    local ue_idx=$2
    local ue_ip=${UE_IPS[$ue_idx]}
    local ue_port=${UE_PORTS[$ue_idx]}
    local ue_id=$((ue_idx + 1))

    local iperf_txt="$OUTPUT_DIR/throughput/iperf_bw${bw}_ue${ue_id}.txt"
    local turbostat_txt="$OUTPUT_DIR/power/turbostat_bw${bw}_ue${ue_id}.txt"

    echo "[UE$ue_id][INFO] Running test at $bw..."

    # Start turbostat
    sudo turbostat --Summary --quiet --show Busy%,Avg_MHz,IRQ,PkgWatt,PkgTmp,RAM_%,RAMWatt --interval 1 > "$turbostat_txt" &
    local turbostat_pid=$!

    # Run iperf3
    iperf3 -c $IPERF_SERVER -B $ue_ip -p $ue_port -b $bw -t $TEST_DURATION > "$iperf_txt"

    # Stop turbostat safely
    sudo kill -SIGINT "$turbostat_pid"
    timeout 3s tail --pid=$turbostat_pid -f /dev/null
}

# Trap cleanup
trap stop_iperf_servers EXIT

# Start servers
start_iperf_servers

# Run for each BW
for bw in "${BANDWIDTH_VALUES[@]}"; do
    echo "==========================================================="
    echo "[INFO] Starting parallel tests for bandwidth: $bw"
    echo "==========================================================="

    for ((i = 0; i < UE_COUNT; i++)); do
        run_test_for_ue "$bw" "$i" &
    done

    wait  # Wait for all UEs to finish for this bandwidth
    echo "[INFO] All UEs completed for $bw"
    echo
done

# Final summary
echo "==========================================================="
echo "[SUCCESS] All tests complete. Results saved in: $OUTPUT_DIR"
echo " - iperf3 logs:       $OUTPUT_DIR/throughput/"
echo " - Turbostat logs:    $OUTPUT_DIR/power/"
echo "==========================================================="

