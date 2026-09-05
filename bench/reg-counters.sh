#!/usr/bin/env bash
# reg-counters.sh — runs on the registry VM. Prints one whitespace-separated
# line of monotonic counters:
#
#   <epoch_seconds> <cpu_busy_jiffies> <cpu_total_jiffies> <rx_bytes> <tx_bytes> <proc_jiffies>
#
# Read once before a scenario and once after; the differences give average CPU
# utilisation and average NIC throughput over exactly the measured window,
# without a sampler process competing with the engine for the CPU it measures.
#
# proc_jiffies is utime+stime of the unit's main PID, so the engine's own cost
# can be separated from the kernel's network and page-cache work on its behalf.
# It is 0 when no unit name is given or the unit is not running.

set -euo pipefail
UNIT="${1:-}"

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
total=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
busy=$(( total - idle - iowait ))

rx=0
tx=0
for dir in /sys/class/net/*; do
  iface="$(basename "$dir")"
  [ "$iface" = "lo" ] && continue
  [ -r "$dir/statistics/rx_bytes" ] || continue
  rx=$(( rx + $(cat "$dir/statistics/rx_bytes") ))
  tx=$(( tx + $(cat "$dir/statistics/tx_bytes") ))
done

proc=0
if [ -n "$UNIT" ]; then
  pid="$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)"
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/stat" ]; then
    # Fields 14 and 15 of /proc/<pid>/stat are utime and stime. comm (field 2)
    # can contain spaces inside parentheses, so cut everything up to the last
    # ')' before counting fields.
    rest="$(sed 's/^.*) //' "/proc/$pid/stat")"
    # After the cut, field 1 is state, so utime is 12 and stime is 13.
    proc="$(echo "$rest" | awk '{print $12 + $13}')"
  fi
fi

printf '%s %s %s %s %s %s\n' "$(date +%s.%N)" "$busy" "$total" "$rx" "$tx" "$proc"
