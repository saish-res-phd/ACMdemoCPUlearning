import psutil
import subprocess
import time

# EMA smoothing factor
ALPHA = 0.3

# Threshold margin (e.g. 10%)
THRESHOLD_MARGIN = 0.1

# Minimum active cores to keep online
MIN_ACTIVE_CORES = 16

# EMA variables initialized to None
ema_load = None
ema_irq = None
ema_ipc = None

active_cores = set()
offline_cores = set()

def update_ema(prev_ema, new_value, alpha=ALPHA):
    if prev_ema is None:
        return new_value
    return alpha * new_value + (1 - alpha) * prev_ema

def get_cpu_load():
    return psutil.cpu_percent(interval=1)

def get_irq_count(interface="eno1"):
    try:
        with open("/proc/interrupts", "r") as f:
            lines = f.readlines()
        irq_total = 0
        for line in lines:
            if interface in line:
                parts = line.split()
                # sum all integer fields before interface token
                for token in parts[1:]:
                    if token == interface:
                        break
                    try:
                        irq_total += int(token)
                    except:
                        pass
        return irq_total
    except Exception as e:
        print(f"[ERROR] Error fetching IRQ count: {e}")
        return 0

def get_ipc():
    try:
        output = subprocess.check_output("perf stat -e instructions,cycles sleep 1 2>&1", shell=True).decode()
        instr_line = next(line for line in output.splitlines() if "instructions" in line)
        cycles_line = next(line for line in output.splitlines() if "cycles" in line)
        instructions = int(instr_line.split()[0].replace(",", ""))
        cycles = int(cycles_line.split()[0].replace(",", ""))
        return instructions / cycles if cycles != 0 else 0
    except Exception as e:
        print(f"[ERROR] Error fetching IPC: {e}")
        return 0

def get_cpu_frequency(core_id):
    try:
        with open(f"/sys/devices/system/cpu/cpu{core_id}/cpufreq/scaling_cur_freq", "r") as f:
            return int(f.read().strip())
    except:
        return 0

def set_cpu_online_state(core_id, state):
    try:
        with open(f"/sys/devices/system/cpu/cpu{core_id}/online", "w") as f:
            f.write("1" if state == "online" else "0")
        print(f"[INFO] Set core {core_id} to {state}.")
    except IOError as e:
        print(f"[ERROR] Failed to set core {core_id} to {state}: {e}")

def set_governor(governor):
    for core_id in range(psutil.cpu_count()):
        try:
            with open(f"/sys/devices/system/cpu/cpu{core_id}/cpufreq/scaling_governor", "w") as f:
                f.write(governor)
        except IOError:
            pass

def get_active_cores():
    cores = []
    for i in range(psutil.cpu_count()):
        try:
            with open(f"/sys/devices/system/cpu/cpu{i}/online", "r") as f:
                if f.read().strip() == "1":
                    cores.append(i)
        except FileNotFoundError:
            continue
    return cores

def display_core_usage_and_state():
    global active_cores
    per_core_usage = psutil.cpu_percent(percpu=True)
    total_cores = len(per_core_usage)
    print("\nCore Usage and State:")
    print("+-----------+-------------+---------+------------------+")
    print("|   Core ID |   Usage (%) | State   | CPU Freq (MHz)   |")
    print("+===========+=============+=========+==================+")
    active_cores = []

    for core_id in range(total_cores):
        try:
            with open(f"/sys/devices/system/cpu/cpu{core_id}/online", "r") as f:
                state = "online" if f.read().strip() == "1" else "offline"
        except FileNotFoundError:
            continue

        usage = per_core_usage[core_id]
        freq = get_cpu_frequency(core_id) / 1000
        if state == "online":
            active_cores.append(core_id)

        print(f"| {core_id:<9} | {usage:<11.2f} | {state:<7} | {freq:<16.0f} |")
        print("+-----------+-------------+---------+------------------+")

def display_metrics(cpu_load, irq_count, ipc):
    print("\nMetrics                           Value")
    print("-----------------------------------------")
    print(f"EMA CPU Load (%)                  {cpu_load:.2f}")
    print(f"EMA Total IRQ Count               {irq_count:.2f}")
    print(f"EMA IPC                          {ipc:.2f}")
    print(f"Active Cores                     {len(active_cores)}")

def dynamic_threshold_ema(ema_value):
    if ema_value is None:
        return None
    return ema_value * (1 + THRESHOLD_MARGIN)

def manage_core_activity(cpu_load, irq_count, ipc):
    global active_cores, offline_cores

    load_threshold = dynamic_threshold_ema(cpu_load)
    irq_threshold = dynamic_threshold_ema(irq_count)
    ipc_threshold = dynamic_threshold_ema(ipc)

    print(f"[DEBUG] Thresholds: Load={load_threshold}, IRQ={irq_threshold}, IPC={ipc_threshold}")
    print(f"[DEBUG] Current: Load={cpu_load}, IRQ={irq_count}, IPC={ipc:.2f}")

    if all(thresh is not None for thresh in [load_threshold, irq_threshold, ipc_threshold]):
        if cpu_load < load_threshold and irq_count < irq_threshold and ipc < ipc_threshold and len(active_cores) > MIN_ACTIVE_CORES:
            core_to_deactivate = active_cores.pop()
            offline_cores.add(core_to_deactivate)
            set_cpu_online_state(core_to_deactivate, 'offline')
            set_governor("powersave")
            print(f"[INFO] Deactivated core {core_to_deactivate}.")
        elif cpu_load >= load_threshold or irq_count >= irq_threshold or ipc >= ipc_threshold:
            if offline_cores:
                core_to_activate = offline_cores.pop()
                active_cores.append(core_to_activate)
                set_cpu_online_state(core_to_activate, 'online')
                set_governor("performance")
                print(f"[INFO] Activated core {core_to_activate}.")

    # Reassign processes off offline cores to active cores
    process_ids_to_reassign = []
    for proc in psutil.process_iter(['pid', 'cpu_num']):
        try:
            if proc.info['cpu_num'] not in active_cores:
                process_ids_to_reassign.append(proc.info['pid'])
                psutil.Process(proc.info['pid']).cpu_affinity(active_cores[:1])
        except Exception:
            continue

    if process_ids_to_reassign:
        print(f"[INFO] Reassigned processes: {', '.join(map(str, process_ids_to_reassign))}")

    print(f"[INFO] Active cores: {', '.join(map(str, active_cores))}")

def main():
    global ema_load, ema_irq, ema_ipc, active_cores, offline_cores
    active_cores = get_active_cores()
    offline_cores = set()

    while True:
        raw_cpu_load = get_cpu_load()
        raw_irq_count = get_irq_count()
        raw_ipc = get_ipc()

        # Update EMA values
        ema_load = update_ema(ema_load, raw_cpu_load)
        ema_irq = update_ema(ema_irq, raw_irq_count)
        ema_ipc = update_ema(ema_ipc, raw_ipc)

        display_metrics(ema_load, ema_irq, ema_ipc)
        manage_core_activity(ema_load, ema_irq, ema_ipc)
        display_core_usage_and_state()

        time.sleep(5)

if __name__ == "__main__":
    main()
