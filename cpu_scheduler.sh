#!/bin/bash

# Get PID of gNodeB (e.g., UERANSIM's nr-gnb)
GNB_PID=$(pgrep -f "build/nr-gnb")

if [ -z "$GNB_PID" ]; then
  echo "gNodeB process not found!"
  exit 1
fi

echo "gNodeB PID: $GNB_PID"
echo "Applying CPU scheduling policy: $1"

case "$1" in

  fcfs)
    echo "[FCFS] Default Linux CFS behavior (no changes)."
    # No action needed
    ;;

  sjf)
    echo "[SJF] Simulating shorter burst with higher priority."
    renice -n -10 -p "$GNB_PID"
    ;;

  srtf)
    echo "[SRTF] Simulating preemptive shortest remaining time."
    echo "This needs manual tracking of CPU time."
    # Placeholder for dynamic scripting
    renice -n -10 -p "$GNB_PID"
    ;;

  rr)
    echo "[Round Robin] Pin to all CPUs for time-sharing effect."
    taskset -cp 0-$(($(nproc)-1)) "$GNB_PID"
    ;;

  priority-pre)
    echo "[Priority Scheduling - Preemptive] Set high priority."
    renice -n -15 -p "$GNB_PID"
    ;;

  priority-nonpre)
    echo "[Priority Scheduling - Non-Preemptive] Low priority."
    renice -n +10 -p "$GNB_PID"
    ;;

  hrrn)
    echo "[HRRN] Simulating HRRN by increasing priority over time."
    # Needs dynamic calculation; use placeholder
    renice -n -5 -p "$GNB_PID"
    ;;

  mlq)
    echo "[MLQ] Assigning to fixed CPU core simulating a queue."
    taskset -cp 2 "$GNB_PID"
    ;;

  mlfq)
    echo "[MLFQ] Simulating feedback queue: start high, degrade later."
    renice -n -5 -p "$GNB_PID"
    sleep 10
    echo "Demoting priority..."
    renice -n +5 -p "$GNB_PID"
    ;;

  reset)
    echo "[Reset] Restoring default settings..."
    renice -n 0 -p "$GNB_PID"
    taskset -cp 0-$(($(nproc)-1)) "$GNB_PID"
    ;;

  *)
    echo "Usage: $0 {fcfs|sjf|srtf|rr|priority-pre|priority-nonpre|hrrn|mlq|mlfq|reset}"
    exit 1
    ;;
esac

