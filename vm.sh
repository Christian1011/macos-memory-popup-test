#!/bin/bash
# vm.sh: one person's VM freezes, moves to swap and comes back intact (root, on a disposable runner).
# The guest fills 1 GiB of its RAM with random bytes and prints the md5; after freeze, reclaim and thaw it must print the same md5.
set -u
out=$PWD/out-vm; mkdir -p "$out"; log=$out/events.txt
note() { echo "$(date -u +%T) $*" | tee -a "$log"; }
mib() { echo $(( $(cat "$1") / 1048576 )); }
answer() { # answer PATTERN: wait for the guest line matching PATTERN after the last check sent; print ms since sending
  for i in $(seq 600); do
    l=$(awk -v t="$sent" '$1 > t' "$out/serial.log" | grep -E -m1 "$1") && { echo "$(( $(echo "$l" | cut -d' ' -f1 | tr -d .) / 1000000 - sent / 1000000 )) ms: ${l#* }"; return; }
    sleep 0.2
  done; echo "no answer"
}

apt-get update -qq && apt-get install -y -qq qemu-system-x86 busybox-static cpio >/dev/null
mkdir -p /etc/systemd/system/user-.slice.d
printf '[Slice]\nMemoryMax=6G\nMemorySwapMax=1500M\n' > /etc/systemd/system/user-.slice.d/50-person.conf
systemctl daemon-reload
note "$(ls -l /dev/kvm 2>&1); $(free -m | awk '/Mem|Swap/{printf "%s %s MB  ", $1, $2}')"

root=$(mktemp -d); mkdir -p "$root/bin" "$root/dev" && cp /bin/busybox "$root/bin/" && mknod "$root/dev/console" c 5 1
cat > "$root/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox --install -s /bin
mkdir -p /proc && mount -t proc proc /proc && mount -t devtmpfs dev /dev && mkdir -p /dev/shm && mount -t tmpfs -o size=1200m tmpfs /dev/shm
dd if=/dev/urandom of=/dev/shm/blob bs=1M count=1024 2>/dev/null
echo "ready $(md5sum /dev/shm/blob | cut -c1-32)"
while read cmd; do echo "sum $(md5sum /dev/shm/blob | cut -c1-32)"; done
INIT
chmod +x "$root/init" && (cd "$root" && find . | cpio -o -H newc 2>/dev/null | gzip) > "$out/initrd.gz"

mkfifo "$out/ser.in" "$out/ser.out"
( while IFS= read -r line; do echo "$(date +%s%N) $line"; done < "$out/ser.out" >> "$out/serial.log" ) &
sent=$(date +%s%N)
systemd-run -q --slice=user-3001.slice --unit=carol-vm qemu-system-x86_64 -accel kvm -accel tcg -m 1600 -smp 2 \
  -display none -no-reboot -kernel "/boot/vmlinuz-$(uname -r)" -initrd "$out/initrd.gz" \
  -append "console=ttyS0 quiet panic=-1" -chardev pipe,id=s0,path="$out/ser" -serial chardev:s0 -monitor none
note "carol boots: $(answer '^[0-9]+ ready ')"
cg=/sys/fs/cgroup/user.slice/user-3001.slice
note "carol's VM: $(mib $cg/memory.current) MiB in RAM"

systemctl freeze carol-vm.service
echo 4G > $cg/memory.reclaim 2>/dev/null
note "frozen + reclaimed: $(mib $cg/memory.current) MiB in RAM, $(mib $cg/memory.swap.current) MiB in swap"
sleep 5
systemctl thaw carol-vm.service
for n in 1 2; do
  sent=$(date +%s%N); echo sum > "$out/ser.in"
  note "sum $n after thaw: $(answer '^[0-9]+ sum [0-9a-f]{32}')"
done
systemctl freeze carol-vm.service
echo 4G > $cg/memory.reclaim 2>/dev/null
note "frozen + reclaimed again: $(mib $cg/memory.current) MiB in RAM, $(mib $cg/memory.swap.current) MiB in swap"
note "$(python3 -I prefetch.py $cg)"
sleep 1
note "after prefetch, still frozen: $(mib $cg/memory.current) MiB in RAM"
systemctl thaw carol-vm.service
sent=$(date +%s%N); echo sum > "$out/ser.in"
note "sum 3 after prefetched thaw: $(answer '^[0-9]+ sum [0-9a-f]{32}')"
note "after: $(mib $cg/memory.current) MiB in RAM, $(mib $cg/memory.swap.current) MiB in swap; $(systemctl show -p ActiveState carol-vm.service)"
systemctl stop carol-vm.service

python3 -I - "$log" <<'PY' | tee "$out/verdict.txt"
import re, sys
log = open(sys.argv[1]).read()
sums = re.findall(r"(?:ready|sum) ([0-9a-f]{32})", log)
ms = [int(x) for x in re.findall(r"sum \d after (?:prefetched )?thaw: (\d+) ms", log)]
swap = re.search(r"frozen \+ reclaimed: (\d+) MiB in RAM, (\d+) MiB in swap", log)
print(f"md5s {sums}; full-memory reads after thaw: lazy {ms[0] if ms else '?'} ms, warm {ms[1] if len(ms) > 1 else '?'} ms, prefetched {ms[2] if len(ms) > 2 else '?'} ms; frozen VM {swap.group(1)} MiB in RAM, {swap.group(2)} MiB in swap" if swap else "no reclaim line")
ok = len(sums) == 4 and len(set(sums)) == 1 and swap and int(swap.group(2)) > 500
print("PASS: the VM froze to swap and came back with its memory intact" if ok else "FAIL")
PY
