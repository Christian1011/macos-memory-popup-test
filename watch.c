// watch [--reserve PATH]: logs the kernel's memory-pressure and low-disk events.
// With --reserve, deletes PATH at the first warning or critical memory pressure.
#include <sys/event.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef EVFILT_MEMORYSTATUS
#define EVFILT_MEMORYSTATUS (-14)
#endif
#define WARN 0x2
#define CRITICAL 0x4
#define LOW_SWAP 0x8 // the event loginwindow turns into the "out of application memory" panel

static void stamp(const char *what) {
  struct xsw_usage sw; size_t n = sizeof sw; sysctlbyname("vm.swapusage", &sw, &n, NULL, 0);
  struct statfs fs; statfs("/System/Volumes/Data", &fs);
  struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
  printf("%ld.%03ld %-28s swap %llu/%llu MB, disk free %llu MB\n", t.tv_sec, t.tv_nsec / 1000000, what,
         sw.xsu_used >> 20, sw.xsu_total >> 20, ((unsigned long long)fs.f_bavail * fs.f_bsize) >> 20);
  fflush(stdout);
}

int main(int argc, char **argv) {
  const char *reserve = argc > 2 && !strcmp(argv[1], "--reserve") ? argv[2] : NULL;
  int kq = kqueue();
  struct kevent ev[2];
  EV_SET(&ev[0], 0, EVFILT_MEMORYSTATUS, EV_ADD, 0x1 | WARN | CRITICAL | LOW_SWAP, 0, NULL);
  EV_SET(&ev[1], 0, EVFILT_FS, EV_ADD, 0, 0, NULL);
  if (kevent(kq, ev, 2, NULL, 0, NULL) < 0) { perror("kevent"); return 1; }
  stamp("watching");
  for (;;) {
    struct kevent e;
    if (kevent(kq, NULL, 0, &e, 1, NULL) != 1) continue;
    char what[64];
    if (e.filter == EVFILT_MEMORYSTATUS)
      snprintf(what, sizeof what, "memory 0x%x%s", e.fflags, (e.fflags & LOW_SWAP) ? " LOW_SWAP" : "");
    else
      snprintf(what, sizeof what, "disk 0x%x%s", e.fflags, (e.fflags & (VQ_LOWDISK | VQ_VERYLOWDISK)) ? " LOW" : "");
    stamp(what);
    if (reserve && e.filter == EVFILT_MEMORYSTATUS && (e.fflags & (WARN | CRITICAL | LOW_SWAP)) && unlink(reserve) == 0) {
      stamp("reserve released");
      reserve = NULL;
    }
  }
}
