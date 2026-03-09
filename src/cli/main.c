#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "webwrap/webwrap.h"

static int run_sum_command(int argc, char **argv) {
    int a;
    int b;

    if (argc != 4) {
        fprintf(stderr, "usage: %s sum <a> <b>\n", argv[0]);
        return 1;
    }

    a = atoi(argv[2]);
    b = atoi(argv[3]);
    printf("%d\n", ww_sum(a, b));
    return 0;
}

static int run_get_command(int argc, char **argv) {
    ww_client_t *client = NULL;
    ww_response_t *response = NULL;
    ww_client_options_t options;
    ww_backend_t backend = WW_BACKEND_AUTO;
    ww_error_t error;
    int argi;

    if (argc < 3) {
        fprintf(stderr, "usage: %s get <url> [--backend <name>]\n", argv[0]);
        return 1;
    }

    ww_client_options_init(&options);
    ww_error_clear(&error);

    argi = 3;
    while (argi < argc) {
        if (strcmp(argv[argi], "--backend") == 0 && argi + 1 < argc) {
            if (ww_backend_parse(argv[argi + 1], &backend) != 0) {
                fprintf(stderr, "unknown backend: %s\n", argv[argi + 1]);
                return 1;
            }

            options.backend = backend;
            argi += 2;
            continue;
        }

        fprintf(stderr, "unknown argument: %s\n", argv[argi]);
        return 1;
    }

    if (ww_client_open(&client, &options, &error) != 0) {
        fprintf(stderr, "client open failed: %s\n", error.value);
        return 1;
    }

    if (ww_client_get(client, argv[2], &response, &error) != 0) {
        fprintf(stderr, "request failed: %s\n", error.value);
        ww_client_close(client);
        return 1;
    }

    printf("backend: %s\n", ww_backend_name(ww_client_backend(client)));
    printf("status: %d\n", ww_response_status_code(response));
    if (ww_response_body(response) != NULL) {
        fwrite(ww_response_body(response), 1, ww_response_body_length(response), stdout);
    }

    if (ww_response_body_length(response) == 0U ||
        ww_response_body(response)[ww_response_body_length(response) - 1U] != '\n') {
        fputc('\n', stdout);
    }

    ww_response_close(response);
    ww_client_close(client);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 1) {
        printf("%d\n", ww_sum(2, 3));
        return 0;
    }

    if (strcmp(argv[1], "sum") == 0) {
        return run_sum_command(argc, argv);
    }

    if (strcmp(argv[1], "get") == 0) {
        return run_get_command(argc, argv);
    }

    fprintf(stderr, "usage: %s <sum|get> ...\n", argv[0]);
    return 1;
}
