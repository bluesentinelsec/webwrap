#include <stdlib.h>
#include <string.h>

#include "webwrap/webwrap.h"

struct ww_client {
    ww_backend_t backend;
};

struct ww_server {
    ww_backend_t backend;
    unsigned int workers;
};

static void ww_error_set(ww_error_t *error, ww_error_type_t type, const char *value) {
    if (error == NULL) {
        return;
    }

    error->type = type;
    error->value = value;
    error->length = value == NULL ? 0U : strlen(value);
}

static ww_backend_t ww_select_backend(ww_backend_t requested, ww_backend_t default_backend, ww_error_t *error) {
    ww_backend_t selected = requested == WW_BACKEND_AUTO ? default_backend : requested;

    if (!ww_backend_is_available(selected)) {
        ww_error_set(error, WW_ERROR_BACKEND_UNAVAILABLE, "requested backend is unavailable on this platform");
        return WW_BACKEND_AUTO;
    }

    ww_error_clear(error);
    return selected;
}

int ww_sum(int a, int b) {
    return a + b;
}

void ww_error_clear(ww_error_t *error) {
    if (error == NULL) {
        return;
    }

    error->type = WW_ERROR_NONE;
    error->value = NULL;
    error->length = 0U;
}

const char *ww_error_type_name(ww_error_type_t type) {
    switch (type) {
        case WW_ERROR_NONE:
            return "none";
        case WW_ERROR_INVALID_ARGUMENT:
            return "invalid_argument";
        case WW_ERROR_BACKEND_UNAVAILABLE:
            return "backend_unavailable";
    }

    return "unknown";
}

const char *ww_backend_name(ww_backend_t backend) {
    switch (backend) {
        case WW_BACKEND_AUTO:
            return "auto";
        case WW_BACKEND_BUILTIN:
            return "builtin";
        case WW_BACKEND_CURL:
            return "curl";
        case WW_BACKEND_WINHTTP:
            return "winhttp";
        case WW_BACKEND_CFNETWORK:
            return "cfnetwork";
        case WW_BACKEND_FETCH:
            return "fetch";
    }

    return "unknown";
}

int ww_backend_is_available(ww_backend_t backend) {
    switch (backend) {
        case WW_BACKEND_AUTO:
        case WW_BACKEND_BUILTIN:
            return 1;
        case WW_BACKEND_CURL:
#if defined(__linux__)
            return 1;
#else
            return 0;
#endif
        case WW_BACKEND_WINHTTP:
#if defined(_WIN32)
            return 1;
#else
            return 0;
#endif
        case WW_BACKEND_CFNETWORK:
#if defined(__APPLE__)
            return 1;
#else
            return 0;
#endif
        case WW_BACKEND_FETCH:
#if defined(__EMSCRIPTEN__)
            return 1;
#else
            return 0;
#endif
    }

    return 0;
}

ww_backend_t ww_default_client_backend(void) {
#if defined(__EMSCRIPTEN__)
    return WW_BACKEND_FETCH;
#elif defined(_WIN32)
    return WW_BACKEND_WINHTTP;
#elif defined(__APPLE__)
    return WW_BACKEND_CFNETWORK;
#elif defined(__linux__)
    return WW_BACKEND_CURL;
#else
    return WW_BACKEND_BUILTIN;
#endif
}

ww_backend_t ww_default_server_backend(void) {
    return WW_BACKEND_BUILTIN;
}

void ww_client_options_init(ww_client_options_t *options) {
    if (options == NULL) {
        return;
    }

    options->backend = WW_BACKEND_AUTO;
}

void ww_server_options_init(ww_server_options_t *options) {
    if (options == NULL) {
        return;
    }

    options->backend = WW_BACKEND_AUTO;
    options->workers = 0U;
}

int ww_client_open(ww_client_t **out_client, const ww_client_options_t *options, ww_error_t *error) {
    ww_backend_t requested = WW_BACKEND_AUTO;
    ww_backend_t selected;
    ww_client_t *client;

    if (out_client == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "out_client must not be null");
        return -1;
    }

    *out_client = NULL;
    if (options != NULL) {
        requested = options->backend;
    }

    selected = ww_select_backend(requested, ww_default_client_backend(), error);
    if (selected == WW_BACKEND_AUTO) {
        return -1;
    }

    client = (ww_client_t *)malloc(sizeof(*client));
    if (client == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "failed to allocate client");
        return -1;
    }

    client->backend = selected;
    *out_client = client;
    ww_error_clear(error);
    return 0;
}

void ww_client_close(ww_client_t *client) {
    free(client);
}

ww_backend_t ww_client_backend(const ww_client_t *client) {
    if (client == NULL) {
        return WW_BACKEND_AUTO;
    }

    return client->backend;
}

int ww_server_open(ww_server_t **out_server, const ww_server_options_t *options, ww_error_t *error) {
    ww_backend_t requested = WW_BACKEND_AUTO;
    ww_backend_t selected;
    ww_server_t *server;

    if (out_server == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "out_server must not be null");
        return -1;
    }

    *out_server = NULL;
    if (options != NULL) {
        requested = options->backend;
    }

    selected = ww_select_backend(requested, ww_default_server_backend(), error);
    if (selected == WW_BACKEND_AUTO) {
        return -1;
    }

    server = (ww_server_t *)malloc(sizeof(*server));
    if (server == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "failed to allocate server");
        return -1;
    }

    server->backend = selected;
    server->workers = options == NULL ? 0U : options->workers;
    *out_server = server;
    ww_error_clear(error);
    return 0;
}

void ww_server_close(ww_server_t *server) {
    free(server);
}

ww_backend_t ww_server_backend(const ww_server_t *server) {
    if (server == NULL) {
        return WW_BACKEND_AUTO;
    }

    return server->backend;
}

unsigned int ww_server_workers(const ww_server_t *server) {
    if (server == NULL) {
        return 0U;
    }

    return server->workers;
}
