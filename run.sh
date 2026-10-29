#!/bin/bash
# run.sh control|reserve|caps: one trial on a disposable macOS runner.
#   control  nearly full disk + 4 memory hogs
#   reserve  same, with an 8 GiB reserve file released at the first memory pressure
#   caps     same, with each hog started under a 1 GiB fatal memory cap
set -u
phase=$1 out=out-$1 V=/System/Volumes/Data
mkdir -p "$out"
freemb() { df -m "$V" | awk 'NR==2 {print $4}'; }
{ sw_vers; sysctl hw.memsize hw.ncpu vm.swapusage; df -m "$V"; } > "$out/machine.txt"
start=$(date '+%Y-%m-%d %H:%M:%S')

[ "$phase" = reserve ] && dd if=/dev/zero of="$HOME/reserve" bs=64m count=128 2>/dev/null
./watch $([ "$phase" = reserve ] && echo --reserve "$HOME/reserve") --fill "$HOME/fill" > "$out/events.txt" &
watcher=$!
n=$(( ($(freemb) - 600) / 64 ))
[ "$n" -gt 0 ] && dd if=/dev/zero of="$HOME/fill" bs=64m count="$n" 2>/dev/null
echo "free after fill: $(freemb) MB" >> "$out/machine.txt"

cap=""; [ "$phase" = caps ] && cap="./capexec 1024"
pids=()
for i in 1 2 3 4; do $cap ./hog 2560 60 > "$out/hog$i.txt" 2>&1 & pids+=($!); done
# A starved disk silences the runner itself, so the trial frees its disk after 6 minutes whatever happens.
( sleep 360; rm -f "$HOME/fill"; pkill -x hog ) & guard=$!
for i in 0 1 2 3; do wait "${pids[$i]}"; echo "hog$((i + 1)) exit $?" >> "$out/exits.txt"; done
sleep 5
kill "$watcher" "$guard" 2>/dev/null
rm -f "$HOME/fill" "$HOME/reserve"

log show --start "$start" --style compact --predicate 'sender == "kernel" AND (eventMessage CONTAINS[c] "paging" OR eventMessage CONTAINS[c] "memorystatus" OR eventMessage CONTAINS[c] "swap")' > "$out/kernel.txt" 2>&1
log show --start "$start" --style compact --predicate 'process == "loginwindow" AND eventMessage CONTAINS[c] "memory"' > "$out/loginwindow.txt" 2>&1
grep -q LOW_SWAP "$out/events.txt" && verdict="LOW_SWAP fired (the popup's trigger)" || verdict="no LOW_SWAP"
echo "$phase: $verdict" | tee "$out/verdict.txt"
cat "$out/exits.txt" "$out/events.txt"
