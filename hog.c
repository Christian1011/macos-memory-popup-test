// hog MiB SECONDS: fills MiB of random (incompressible) memory in 64 MiB steps, then holds it.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(int argc, char **argv) {
  int target = atoi(argv[1]), hold = atoi(argv[2]);
  for (int mb = 64; mb <= target; mb += 64) {
    char *p = malloc(64u << 20);
    if (!p) { printf("malloc failed at %d MiB\n", mb); break; }
    arc4random_buf(p, 64u << 20);
    if (mb % 512 == 0) { printf("at %d MiB\n", mb); fflush(stdout); }
    usleep(50000);
  }
  printf("holding\n"); fflush(stdout);
  sleep(hold);
  return 0;
}
