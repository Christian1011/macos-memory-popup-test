# prefetch.py CGROUP_DIR: asks the kernel to read every swapped-out page of a frozen cgroup back in, in parallel,
# so the first request after thaw finds its memory in RAM. process_madvise(MADV_WILLNEED) works on stopped tasks.
import ctypes, os, sys, time

libc = ctypes.CDLL(None, use_errno=True)
SYS_pidfd_open, SYS_process_madvise, MADV_WILLNEED, UIO_MAXIOV = 434, 440, 3, 1024


class iovec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def pids(cg):
    for d, _, files in os.walk(cg):
        if "cgroup.procs" in files:
            yield from (int(p) for p in open(os.path.join(d, "cgroup.procs")).read().split())


def anon_ranges(pid):
    for line in open(f"/proc/{pid}/maps"):
        f = line.split()
        if "w" in f[1] and (len(f) < 6 or f[5].startswith("[")):
            lo, hi = (int(x, 16) for x in f[0].split("-"))
            yield lo, hi - lo


start, asked, failed = time.monotonic(), 0, 0
for pid in pids(sys.argv[1]):
    fd = libc.syscall(SYS_pidfd_open, pid, 0)
    ranges = list(anon_ranges(pid))
    for i in range(0, len(ranges), UIO_MAXIOV):
        chunk = ranges[i:i + UIO_MAXIOV]
        iov = (iovec * len(chunk))(*[iovec(lo, n) for lo, n in chunk])
        if libc.syscall(SYS_process_madvise, fd, iov, len(chunk), MADV_WILLNEED, 0) < 0:
            failed += 1
        asked += sum(n for _, n in chunk)
    os.close(fd)
print(f"prefetch asked for {asked >> 20} MiB in {int((time.monotonic() - start) * 1000)} ms ({failed} calls failed)")
