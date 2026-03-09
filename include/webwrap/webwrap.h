#ifndef WEBWRAP_WEBWRAP_H
#define WEBWRAP_WEBWRAP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ww_client ww_client_t;
typedef struct ww_server ww_server_t;

typedef enum ww_backend {
    WW_BACKEND_AUTO = 0,
    WW_BACKEND_BUILTIN,
    WW_BACKEND_CURL,
    WW_BACKEND_WINHTTP,
    WW_BACKEND_CFNETWORK,
    WW_BACKEND_FETCH
} ww_backend_t;

typedef enum ww_error_type {
    WW_ERROR_NONE = 0,
    WW_ERROR_INVALID_ARGUMENT,
    WW_ERROR_BACKEND_UNAVAILABLE
} ww_error_type_t;

typedef struct ww_error {
    ww_error_type_t type;
    const char *value;
    size_t length;
} ww_error_t;

typedef struct ww_client_options {
    ww_backend_t backend;
} ww_client_options_t;

typedef struct ww_server_options {
    ww_backend_t backend;
    unsigned int workers;
} ww_server_options_t;

int ww_sum(int a, int b);

void ww_error_clear(ww_error_t *error);
const char *ww_error_type_name(ww_error_type_t type);

const char *ww_backend_name(ww_backend_t backend);
int ww_backend_is_available(ww_backend_t backend);
ww_backend_t ww_default_client_backend(void);
ww_backend_t ww_default_server_backend(void);

void ww_client_options_init(ww_client_options_t *options);
void ww_server_options_init(ww_server_options_t *options);

int ww_client_open(ww_client_t **out_client, const ww_client_options_t *options, ww_error_t *error);
void ww_client_close(ww_client_t *client);
ww_backend_t ww_client_backend(const ww_client_t *client);

int ww_server_open(ww_server_t **out_server, const ww_server_options_t *options, ww_error_t *error);
void ww_server_close(ww_server_t *server);
ww_backend_t ww_server_backend(const ww_server_t *server);
unsigned int ww_server_workers(const ww_server_t *server);

#ifdef __cplusplus
}
#endif

#endif
