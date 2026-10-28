#!/bin/bash
# linux.sh: two people share one Linux box, each in their own user slice (root, on a disposable runner).
# ann's warm tsserver is frozen and reclaimed to swap; bob runs away past his MemoryMax; ann thaws warm.
set -u
out=$PWD/out-linux; mkdir -p "$out"; log=$out/events.txt
note() { echo "$(date -u +%T) $*" | tee -a "$log"; }
mib() { echo $(( $(cat "$1") / 1048576 )); }

for p in ann bob; do id "$p" >/dev/null 2>&1 || useradd -m "$p"; done
mkdir -p /etc/systemd/system/user-.slice.d
printf '[Slice]\nMemoryHigh=5G\nMemoryMax=6G\n' > /etc/systemd/system/user-.slice.d/50-person.conf
systemctl daemon-reload
note "kernel $(uname -r); $(systemctl --version | head -1); $(free -m | awk '/Mem|Swap/{printf "%s %s MB  ", $1, $2}')"

probe=/home/ann/probe; mkdir -p "$probe" && cp lsp-probe.mjs "$probe/"
(cd "$probe" && npm i --silent --no-audit --no-fund typescript@5.9.2 >/dev/null)
git clone -q --depth 1 --branch v5.9.2 https://github.com/microsoft/TypeScript /home/ann/TypeScript
chown -R ann: /home/ann
ann=$(id -u ann); bob=$(id -u bob); cg=/sys/fs/cgroup/user.slice/user-$ann.slice

systemd-run -q --uid=ann --slice=user-$ann.slice --unit=ann-ts -p Environment=HOME=/home/ann \
  node "$probe/lsp-probe.mjs" /home/ann/TypeScript/src/compiler/checker.ts "$probe/log.txt"
for i in $(seq 180); do [ -s "$probe/log.txt" ] && break; sleep 1; done
note "ann: $(tail -1 "$probe/log.txt")"
note "ann slice: $(mib $cg/memory.current) MiB in RAM"

systemctl freeze ann-ts.service
echo 8G > $cg/memory.reclaim 2>/dev/null
note "ann frozen + reclaimed: $(mib $cg/memory.current) MiB in RAM, $(mib $cg/memory.swap.current) MiB in swap"

systemd-run --uid=bob --slice=user-$bob.slice --unit=bob-hog --wait -p Environment=HOME=/home/bob \
  python3 -c 'b = []
while True: b.append(bytearray(256 << 20))' >> "$log" 2>&1
note "bob slice events: $(tr '\n' ' ' < /sys/fs/cgroup/user.slice/user-$bob.slice/memory.events)"
note "ann during: $(systemctl show -p ActiveState -p FreezerState ann-ts.service | tr '\n' ' ')"

systemctl thaw ann-ts.service
pid=$(systemctl show -p MainPID --value ann-ts.service)
for n in 2 3; do
  kill -USR2 "$pid"
  for i in $(seq 120); do [ "$(wc -l < "$probe/log.txt")" -ge $n ] && break; sleep 0.5; done
  note "ann: $(tail -1 "$probe/log.txt")"
done
note "ann slice after thaw: $(mib $cg/memory.current) MiB in RAM, $(mib $cg/memory.swap.current) MiB in swap"
cp "$probe/log.txt" "$out/ann-probe.txt"

python3 -I - "$out/ann-probe.txt" "$log" <<'PY' | tee "$out/verdict.txt"
import re, sys
probe = open(sys.argv[1]).read().splitlines(); log = open(sys.argv[2]).read()
ms = [int(re.search(r"quickinfo (\d+) ms", l).group(1)) for l in probe]
pids = {re.search(r"pid (\d+)", l).group(1) for l in probe}
oom = re.search(r"oom_kill (\d+)", log); oom = int(oom.group(1)) if oom else 0
print(f"cold load {ms[0]} ms, first answer after thaw from swap {ms[1]} ms, warm {ms[2]} ms; tsserver pids {sorted(pids)}")
print(f"bob oom kills {oom}; ann {'stayed active' if 'ActiveState=active' in log else 'was lost'}")
ok = len(ms) == 3 and len(pids) == 1 and oom > 0 and "ActiveState=active" in log and ms[1] < ms[0]
print("PASS: bob died alone and ann came back warm" if ok else "FAIL")
PY
