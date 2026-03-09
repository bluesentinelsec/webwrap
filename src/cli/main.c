#include <stdio.h>
#include <stdlib.h>

#include "webwrap/webwrap.h"

int main(int argc, char **argv) {
    int a = 2;
    int b = 3;

    if (argc == 3) {
        a = atoi(argv[1]);
        b = atoi(argv[2]);
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [a b]\n", argv[0]);
        return 1;
    }

    printf("%d\n", ww_sum(a, b));
    return 0;
}
