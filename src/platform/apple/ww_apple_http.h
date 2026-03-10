#ifndef WEBWRAP_PLATFORM_APPLE_WW_APPLE_HTTP_H
#define WEBWRAP_PLATFORM_APPLE_WW_APPLE_HTTP_H

#include <stddef.h>

#include "webwrap/webwrap.h"

struct ww_header_pair;

int ww_apple_client_send(const char *method,
                         const char *url,
                         const struct ww_header_pair *headers,
                         size_t header_count,
                         const unsigned char *body,
                         size_t body_length,
                         int *out_status_code,
                         char **out_effective_url,
                         char **out_body,
                         size_t *out_body_length,
                         struct ww_header_pair **out_response_headers,
                         size_t *out_response_header_count,
                         ww_error_t *error);

#endif
