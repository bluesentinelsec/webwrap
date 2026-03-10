#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#include "webwrap/webwrap.h"

struct ww_header_pair {
    char *name;
    char *value;
};

struct ww_client {
    ww_backend_t backend;
};

struct ww_request {
    char *method;
    char *url;
    unsigned char *body;
    size_t body_length;
    struct ww_header_pair *headers;
    size_t header_count;
};

struct ww_response {
    int status_code;
    char *effective_url;
    char *body;
    size_t body_length;
    struct ww_header_pair *headers;
    size_t header_count;
};

struct ww_server {
    ww_backend_t backend;
    unsigned int workers;
};

#if defined(__APPLE__)
#include "platform/apple/ww_apple_http.h"
#endif

static void ww_error_set(ww_error_t *error, ww_error_type_t type, const char *value) {
    if (error == NULL) {
        return;
    }

    error->type = type;
    error->value = value;
    error->length = value == NULL ? 0U : strlen(value);
}

static char *ww_string_dup(const char *value) {
    size_t length;
    char *copy;

    if (value == NULL) {
        return NULL;
    }

    length = strlen(value);
    copy = (char *)malloc(length + 1U);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, value, length + 1U);
    return copy;
}

static unsigned char *ww_buffer_dup(const void *data, size_t length) {
    unsigned char *copy;

    if (length == 0U) {
        return NULL;
    }

    copy = (unsigned char *)malloc(length);
    if (copy == NULL) {
        return NULL;
    }

    memcpy(copy, data, length);
    return copy;
}

static void ww_headers_free(struct ww_header_pair *headers, size_t header_count) {
    size_t i;

    if (headers == NULL) {
        return;
    }

    for (i = 0; i < header_count; ++i) {
        free(headers[i].name);
        free(headers[i].value);
    }

    free(headers);
}

static int ww_headers_append(struct ww_header_pair **headers,
                             size_t *header_count,
                             const char *name,
                             const char *value,
                             ww_error_t *error) {
    struct ww_header_pair *grown_headers;
    char *name_copy;
    char *value_copy;

    name_copy = ww_string_dup(name);
    value_copy = ww_string_dup(value);
    if (name_copy == NULL || value_copy == NULL) {
        free(name_copy);
        free(value_copy);
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate header");
        return -1;
    }

    grown_headers = (struct ww_header_pair *)realloc(*headers, (*header_count + 1U) * sizeof(**headers));
    if (grown_headers == NULL) {
        free(name_copy);
        free(value_copy);
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to grow header array");
        return -1;
    }

    grown_headers[*header_count].name = name_copy;
    grown_headers[*header_count].value = value_copy;
    *headers = grown_headers;
    *header_count += 1U;
    ww_error_clear(error);
    return 0;
}

static int ww_ascii_case_equal(const char *left, const char *right) {
    unsigned char left_ch;
    unsigned char right_ch;

    if (left == NULL || right == NULL) {
        return 0;
    }

    while (*left != '\0' && *right != '\0') {
        left_ch = (unsigned char)*left;
        right_ch = (unsigned char)*right;
        if (tolower(left_ch) != tolower(right_ch)) {
            return 0;
        }

        ++left;
        ++right;
    }

    return *left == '\0' && *right == '\0';
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
        case WW_ERROR_NOT_IMPLEMENTED:
            return "not_implemented";
        case WW_ERROR_OUT_OF_MEMORY:
            return "out_of_memory";
        case WW_ERROR_REQUEST_FAILED:
            return "request_failed";
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

int ww_backend_parse(const char *name, ww_backend_t *out_backend) {
    if (name == NULL || out_backend == NULL) {
        return -1;
    }

    if (strcmp(name, "auto") == 0) {
        *out_backend = WW_BACKEND_AUTO;
        return 0;
    }

    if (strcmp(name, "builtin") == 0) {
        *out_backend = WW_BACKEND_BUILTIN;
        return 0;
    }

    if (strcmp(name, "curl") == 0) {
        *out_backend = WW_BACKEND_CURL;
        return 0;
    }

    if (strcmp(name, "winhttp") == 0) {
        *out_backend = WW_BACKEND_WINHTTP;
        return 0;
    }

    if (strcmp(name, "cfnetwork") == 0) {
        *out_backend = WW_BACKEND_CFNETWORK;
        return 0;
    }

    if (strcmp(name, "fetch") == 0) {
        *out_backend = WW_BACKEND_FETCH;
        return 0;
    }

    return -1;
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

int ww_request_open(ww_request_t **out_request, ww_error_t *error) {
    ww_request_t *request;

    if (out_request == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "out_request must not be null");
        return -1;
    }

    *out_request = NULL;
    request = (ww_request_t *)calloc(1U, sizeof(*request));
    if (request == NULL) {
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate request");
        return -1;
    }

    *out_request = request;
    ww_error_clear(error);
    return 0;
}

void ww_request_close(ww_request_t *request) {
    if (request == NULL) {
        return;
    }

    free(request->method);
    free(request->url);
    free(request->body);
    ww_headers_free(request->headers, request->header_count);
    free(request);
}

int ww_request_set_method(ww_request_t *request, const char *method, ww_error_t *error) {
    char *method_copy;

    if (request == NULL || method == NULL || method[0] == '\0') {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request method must not be empty");
        return -1;
    }

    method_copy = ww_string_dup(method);
    if (method_copy == NULL) {
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate request method");
        return -1;
    }

    free(request->method);
    request->method = method_copy;
    ww_error_clear(error);
    return 0;
}

int ww_request_set_url(ww_request_t *request, const char *url, ww_error_t *error) {
    char *url_copy;

    if (request == NULL || url == NULL || url[0] == '\0') {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request url must not be empty");
        return -1;
    }

    url_copy = ww_string_dup(url);
    if (url_copy == NULL) {
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate request url");
        return -1;
    }

    free(request->url);
    request->url = url_copy;
    ww_error_clear(error);
    return 0;
}

int ww_request_add_header(ww_request_t *request, const char *name, const char *value, ww_error_t *error) {
    if (request == NULL || name == NULL || value == NULL || name[0] == '\0') {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request header name and value are required");
        return -1;
    }

    return ww_headers_append(&request->headers, &request->header_count, name, value, error);
}

int ww_request_set_body(ww_request_t *request, const void *body, size_t body_length, ww_error_t *error) {
    unsigned char *body_copy = NULL;

    if (request == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request must not be null");
        return -1;
    }

    if (body_length > 0U && body == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request body pointer must not be null when length is non-zero");
        return -1;
    }

    body_copy = ww_buffer_dup(body, body_length);
    if (body_length > 0U && body_copy == NULL) {
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate request body");
        return -1;
    }

    free(request->body);
    request->body = body_copy;
    request->body_length = body_length;
    ww_error_clear(error);
    return 0;
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
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate client");
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

static int ww_response_alloc(ww_response_t **out_response,
                             int status_code,
                             char *effective_url,
                             char *body,
                             size_t body_length,
                             struct ww_header_pair *headers,
                             size_t header_count,
                             ww_error_t *error) {
    ww_response_t *response;

    response = (ww_response_t *)malloc(sizeof(*response));
    if (response == NULL) {
        free(effective_url);
        free(body);
        ww_headers_free(headers, header_count);
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate response");
        return -1;
    }

    response->status_code = status_code;
    response->effective_url = effective_url;
    response->body = body;
    response->body_length = body_length;
    response->headers = headers;
    response->header_count = header_count;
    *out_response = response;
    ww_error_clear(error);
    return 0;
}

static int ww_builtin_client_send(const ww_request_t *request, ww_response_t **out_response, ww_error_t *error) {
    (void)request;
    (void)out_response;
    ww_error_set(error, WW_ERROR_NOT_IMPLEMENTED, "builtin http client is not implemented yet");
    return -1;
}

static int ww_platform_client_send(ww_backend_t backend,
                                   const ww_request_t *request,
                                   ww_response_t **out_response,
                                   ww_error_t *error) {
    char *effective_url = NULL;
    char *body = NULL;
    size_t body_length = 0U;
    struct ww_header_pair *headers = NULL;
    size_t header_count = 0U;
    int status_code = 0;

    switch (backend) {
        case WW_BACKEND_BUILTIN:
            return ww_builtin_client_send(request, out_response, error);
        case WW_BACKEND_CFNETWORK:
#if defined(__APPLE__)
            if (ww_apple_client_send(request->method,
                                     request->url,
                                     request->headers,
                                     request->header_count,
                                     request->body,
                                     request->body_length,
                                     &status_code,
                                     &effective_url,
                                     &body,
                                     &body_length,
                                     &headers,
                                     &header_count,
                                     error) != 0) {
                return -1;
            }

            return ww_response_alloc(
                out_response, status_code, effective_url, body, body_length, headers, header_count, error);
#else
            ww_error_set(error, WW_ERROR_BACKEND_UNAVAILABLE, "cfnetwork is unavailable on this platform");
            return -1;
#endif
        case WW_BACKEND_AUTO:
        case WW_BACKEND_CURL:
        case WW_BACKEND_WINHTTP:
        case WW_BACKEND_FETCH:
            ww_error_set(error, WW_ERROR_NOT_IMPLEMENTED, "selected backend is not implemented yet");
            return -1;
    }

    ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "selected backend is invalid");
    return -1;
}

int ww_client_send(ww_client_t *client, const ww_request_t *request, ww_response_t **out_response, ww_error_t *error) {
    if (client == NULL || request == NULL || out_response == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "client send requires client, request, and response output");
        return -1;
    }

    if (request->method == NULL || request->url == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request method and url must be set");
        return -1;
    }

    *out_response = NULL;
    return ww_platform_client_send(client->backend, request, out_response, error);
}

static int ww_client_send_simple(ww_client_t *client,
                                 const char *method,
                                 const char *url,
                                 const void *body,
                                 size_t body_length,
                                 ww_response_t **out_response,
                                 ww_error_t *error) {
    ww_request_t *request = NULL;
    int rc = -1;

    if (client == NULL || method == NULL || url == NULL || out_response == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "simple client send requires client, method, url, and response output");
        return -1;
    }

    *out_response = NULL;
    if (ww_request_open(&request, error) != 0) {
        return -1;
    }

    if (ww_request_set_method(request, method, error) != 0) {
        goto cleanup;
    }

    if (ww_request_set_url(request, url, error) != 0) {
        goto cleanup;
    }

    if (body_length > 0U && ww_request_set_body(request, body, body_length, error) != 0) {
        goto cleanup;
    }

    rc = ww_client_send(client, request, out_response, error);

cleanup:
    ww_request_close(request);
    return rc;
}

int ww_client_get(ww_client_t *client, const char *url, ww_response_t **out_response, ww_error_t *error) {
    return ww_client_send_simple(client, "GET", url, NULL, 0U, out_response, error);
}

int ww_client_post(ww_client_t *client,
                   const char *url,
                   const void *body,
                   size_t body_length,
                   ww_response_t **out_response,
                   ww_error_t *error) {
    return ww_client_send_simple(client, "POST", url, body, body_length, out_response, error);
}

int ww_client_put(ww_client_t *client,
                  const char *url,
                  const void *body,
                  size_t body_length,
                  ww_response_t **out_response,
                  ww_error_t *error) {
    return ww_client_send_simple(client, "PUT", url, body, body_length, out_response, error);
}

int ww_client_delete(ww_client_t *client, const char *url, ww_response_t **out_response, ww_error_t *error) {
    return ww_client_send_simple(client, "DELETE", url, NULL, 0U, out_response, error);
}

void ww_response_close(ww_response_t *response) {
    if (response == NULL) {
        return;
    }

    free(response->effective_url);
    free(response->body);
    ww_headers_free(response->headers, response->header_count);
    free(response);
}

int ww_response_status_code(const ww_response_t *response) {
    if (response == NULL) {
        return 0;
    }

    return response->status_code;
}

const char *ww_response_effective_url(const ww_response_t *response) {
    if (response == NULL) {
        return NULL;
    }

    return response->effective_url;
}

const char *ww_response_body(const ww_response_t *response) {
    if (response == NULL) {
        return NULL;
    }

    return response->body;
}

size_t ww_response_body_length(const ww_response_t *response) {
    if (response == NULL) {
        return 0U;
    }

    return response->body_length;
}

size_t ww_response_header_count(const ww_response_t *response) {
    if (response == NULL) {
        return 0U;
    }

    return response->header_count;
}

const char *ww_response_header_name(const ww_response_t *response, size_t index) {
    if (response == NULL || index >= response->header_count) {
        return NULL;
    }

    return response->headers[index].name;
}

const char *ww_response_header_value_at(const ww_response_t *response, size_t index) {
    if (response == NULL || index >= response->header_count) {
        return NULL;
    }

    return response->headers[index].value;
}

const char *ww_response_header_value(const ww_response_t *response, const char *name) {
    size_t i;

    if (response == NULL || name == NULL) {
        return NULL;
    }

    for (i = 0; i < response->header_count; ++i) {
        if (ww_ascii_case_equal(response->headers[i].name, name)) {
            return response->headers[i].value;
        }
    }

    return NULL;
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
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate server");
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
