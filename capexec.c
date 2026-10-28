// capexec MiB cmd args...: replaces itself with cmd under a fatal footprint cap (same pid).
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
extern int posix_spawnattr_setjetsam_ext(posix_spawnattr_t *, short, int, int, int);
extern char **environ;
int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: capexec MiB cmd [args...]\n"); return 64; }
  posix_spawnattr_t a; posix_spawnattr_init(&a);
  posix_spawnattr_setflags(&a, POSIX_SPAWN_SETEXEC);
  posix_spawnattr_setjetsam_ext(&a, 0x04 | 0x08, 180, atoi(argv[1]), atoi(argv[1]));
  pid_t pid; int r = posix_spawnp(&pid, argv[2], NULL, &a, argv + 2, environ);
  perror("capexec"); return r;
}
