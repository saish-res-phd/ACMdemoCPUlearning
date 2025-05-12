#!/bin/bash

# Configuration
IPERF_SERVER="10.45.0.1"
UE_IPS=("10.45.0.43" "10.45.0.44" "10.45.0.46" "10.45.0.47" "10.45.0.48" 
        "10.45.0.49" "10.45.0.50" "10.45.0.51" "10.45.0.52" "10.45.0.53")
UE_COUNT=${#UE_IPS[@]}
TEST_DURATION=100
BANDWIDTH_VALUES=("5G" "10G" "15G" "20G" "25G" "30G" "35G" "40G")
PROTOCOLS=("tcp" "udp")
OUTPUT_DIR="iperf_results_$(date +%Y%m%d_%H%M%S)"
GNB_ID="UERANSIM-gnb-999-70-1"  # Replace with your gNB ID

# Create directories
# Create directory structure
DIRECTORIES=(
    "logs" "cpu_stats" "throughput" "5g_metrics/ue" "5g_metrics/gnb"
    "latency" "container_stats" "power_stats" "timeseries" "network_stats"
)

for dir in "${DIRECTORIES[@]}"; do
    mkdir -p "$OUTPUT_DIR/$dir"/{tcp,udp}
done

# Function to get current timestamp in milliseconds
timestamp_ms() {
    date +%s%3N
}

# Function to collect UE metrics
collect_ue_metrics() {
    local protocol=$1
    local bw=$2
    local ue_num=$3
    local ue_imsi="imsi-99970$(printf "%09d" $((ue_num+1)))"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local out_dir="$OUTPUT_DIR/5g_metrics/ue/$protocol"
    
    {
        echo "=== UE INFO ==="
        ./build/nr-cli $ue_imsi --exec "info" 2>&1
        echo ""
        
        echo "=== UE STATUS ==="
        ./build/nr-cli $ue_imsi --exec "status" 2>&1
        echo ""
        
        echo "=== UE TIMERS ==="
        ./build/nr-cli $ue_imsi --exec "timers" 2>&1
        echo ""
        
        echo "=== UE RLS STATE ==="
        ./build/nr-cli $ue_imsi --exec "rls-state" 2>&1
        echo ""
        
        echo "=== UE COVERAGE ==="
        ./build/nr-cli $ue_imsi --exec "coverage" 2>&1
        echo ""
        
        echo "=== UE PDU SESSIONS ==="
        ./build/nr-cli $ue_imsi --exec "ps-list" 2>&1
        echo ""
    } > "$out_dir/ue_metrics_bw${bw}_ue${ue_num}_${timestamp}.log"
}

# Function to collect gNB metrics
collect_gnb_metrics() {
    local protocol=$1
    local bw=$2
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local out_dir="$OUTPUT_DIR/5g_metrics/gnb/$protocol"
    
    {
        echo "=== gNB INFO ==="
        ./build/nr-cli $GNB_ID --exec "info" 2>&1
        echo ""
        
        echo "=== gNB STATUS ==="
        ./build/nr-cli $GNB_ID --exec "status" 2>&1
        echo ""
        
        echo "=== AMF LIST ==="
        ./build/nr-cli $GNB_ID --exec "amf-list" 2>&1
        echo ""
        
        echo "=== UE LIST ==="
        ./build/nr-cli $GNB_ID --exec "ue-list" 2>&1
        echo ""
        
        echo "=== UE COUNT ==="
        ./build/nr-cli $GNB_ID --exec "ue-count" 2>&1
        echo ""
    } > "$out_dir/gnb_metrics_bw${bw}_${timestamp}.log"
}

# Function to collect time-series radio metrics
collect_radio_metrics() {
    local protocol=$1
    local bw=$2
    local ue_num=$3
    local ue_imsi="imsi-99970$(printf "%09d" $((ue_num+1)))"
    local out_file="$OUTPUT_DIR/timeseries/$protocol/radio_ts_bw${bw}_ue${ue_num}.csv"
    
    # Create CSV header
    echo "timestamp_ms,cell_id,rsrp,sinr,ul_throughput,dl_throughput,latency" > "$out_file"
    
    # Collect data in background
    (
        for ((i=0; i<TEST_DURATION; i++)); do
            local ts=$(timestamp_ms)
            local status=$(./build/nr-cli $ue_imsi --exec "status" 2>/dev/null)
            local cell_id=$(echo "$status" | awk -F': ' '/Current cell/ {print $2}')
            local rsrp=$(echo "$status" | awk -F': ' '/Current RSRP/ {print $2}')
            local sinr=$(echo "$status" | awk -F': ' '/Current SINR/ {print $2}')
            
            # Get throughput from PDU sessions
            local throughput=$(./build/nr-cli $ue_imsi --exec "ps-list" 2>/dev/null | awk -F'|' '/[0-9]/ {print $4,$5}' | tr -s ' ')
            local dl_throughput=$(echo $throughput | awk '{print $1}')
            local ul_throughput=$(echo $throughput | awk '{print $2}')
            
            # Get latency
            local latency=$(ping -c 1 -I uesimtun${ue_num} $IPERF_SERVER | awk -F'/' '/rtt/ {print $5}')
            
            echo "$ts,$cell_id,$rsrp,$sinr,$ul_throughput,$dl_throughput,${latency:-NA}" >> "$out_file"
            sleep 1
        done
    ) &
}

# Function to collect system metrics
collect_system_metrics() {
    local protocol=$1
    local bw=$2
    local ue_num=$3
    local duration=$TEST_DURATION
    
    # Power metrics
    sudo turbostat --quiet --Summary --show Busy%,Bzy_MHz,PkgTmp,PkgWatt,GFXWatt,RAMWatt \
        --interval 1 --num_iterations $duration \
        > "$OUTPUT_DIR/power_stats/$protocol/power_ts_bw${bw}_ue${ue_num}.log" &
    
    # CPU metrics
    mpstat -P ALL 1 $duration > "$OUTPUT_DIR/cpu_stats/$protocol/cpu_ts_bw${bw}_ue${ue_num}.log" &
    
    # Network stats
    (while sleep 1; do
        echo "$(timestamp_ms) $(cat /proc/net/dev | grep "uesimtun${ue_num}")" \
            >> "$OUTPUT_DIR/network_stats/$protocol/net_ts_bw${bw}_ue${ue_num}.log"
    done) &
}

# Function to run iperf test
run_iperf_test() {
    local protocol=$1
    local bw=$2
    local ue_num=$3
    local ue_ip=${UE_IPS[$ue_num]}
    
    if [ "$protocol" == "udp" ]; then
        iperf_cmd="iperf3 -c $IPERF_SERVER -B $ue_ip -u -b $bw -t $TEST_DURATION -J"
    else
        iperf_cmd="iperf3 -c $IPERF_SERVER -B $ue_ip -t $TEST_DURATION -J"
    fi
    
    echo "$(timestamp_ms) Running $protocol test for UE $ue_num (IP: $ue_ip) with $bw"
    $iperf_cmd > "$OUTPUT_DIR/logs/$protocol/iperf_bw${bw}_ue${ue_num}.json" 2>&1
    
    # Process results
    if [ "$protocol" == "udp" ]; then
        jq '.end.sum.bits_per_second/1e9' "$OUTPUT_DIR/logs/$protocol/iperf_bw${bw}_ue${ue_num}.json" \
            > "$OUTPUT_DIR/throughput/$protocol/throughput_bw${bw}_ue${ue_num}.txt"
        jq '.end.sum.lost_percent' "$OUTPUT_DIR/logs/$protocol/iperf_bw${bw}_ue${ue_num}.json" \
            > "$OUTPUT_DIR/throughput/$protocol/loss_bw${bw}_ue${ue_num}.txt"
    else
        jq '.end.sum_received.bits_per_second/1e9' "$OUTPUT_DIR/logs/$protocol/iperf_bw${bw}_ue${ue_num}.json" \
            > "$OUTPUT_DIR/throughput/$protocol/throughput_bw${bw}_ue${ue_num}.txt"
    fi
}

# Main test execution
run_tests() {
    # Initial gNB metrics
    collect_gnb_metrics "initial" "pre_test"
    
    for protocol in "${PROTOCOLS[@]}"; do
        for bw in "${BANDWIDTH_VALUES[@]}"; do
            # gNB metrics before test batch
            collect_gnb_metrics $protocol $bw
            
            for ((ue=0; ue<UE_COUNT; ue++)); do
                echo "================================================================="
                echo "$(timestamp_ms) Starting $protocol test for UE $ue (IP: ${UE_IPS[$ue]}) with $bw"
                echo "================================================================="
                
                # Initial UE metrics
                collect_ue_metrics $protocol $bw $ue
                
                # Start monitoring
                collect_radio_metrics $protocol $bw $ue
                collect_system_metrics $protocol $bw $ue
                
                # Run test
                run_iperf_test $protocol $bw $ue
                
                # Final UE metrics
                collect_ue_metrics $protocol $bw $ue
                
                echo "$(timestamp_ms) Completed $protocol test for UE $ue"
                sleep 15
            done
            
            # gNB metrics after test batch
            collect_gnb_metrics $protocol "${bw}_post"
        done
    done
    
    # Final gNB metrics
    collect_gnb_metrics "final" "post_test"
}

# Generate summary report
generate_summary_report() {
    echo "Generating test summary report..."
    {
        echo "5G Performance Test Summary"
        echo "=========================="
        echo "Test Date: $(date)"
        echo "UE Count: $UE_COUNT"
        echo "Test Duration: $TEST_DURATION seconds"
        echo ""
        
        echo "Throughput Summary:"
        for protocol in "${PROTOCOLS[@]}"; do
            echo "Protocol: $protocol"
            for bw in "${BANDWIDTH_VALUES[@]}"; do
                echo "  Bandwidth: $bw"
                for ((ue=0; ue<UE_COUNT; ue++)); do
                    local log_file="$OUTPUT_DIR/logs/$protocol/iperf_bw${bw}_ue${ue}.json"
                    if [ -f "$log_file" ]; then
                        local throughput=$(jq '.end.sum_received.bits_per_second/1e9' "$log_file" 2>/dev/null)
                        [ "$protocol" == "udp" ] && throughput=$(jq '.end.sum.bits_per_second/1e9' "$log_file" 2>/dev/null)
                        printf "    UE %2d: %.2f Gbps" $ue ${throughput:-0}
                        
                        if [ "$protocol" == "udp" ]; then
                            local loss=$(jq '.end.sum.lost_percent' "$log_file" 2>/dev/null)
                            printf " (Loss: %.2f%%)" ${loss:-0}
                        fi
                        printf "\n"
                    else
                        printf "    UE %2d: N/A\n" $ue
                    fi
                done
            done
        done
    } > "$OUTPUT_DIR/test_summary.txt"
}

# Execute tests
run_tests
generate_summary_report

echo "================================================================="
echo "All tests completed successfully!"
echo "Results stored in: $OUTPUT_DIR"
echo "Summary report: $OUTPUT_DIR/test_summary.txt"
echo "================================================================="
