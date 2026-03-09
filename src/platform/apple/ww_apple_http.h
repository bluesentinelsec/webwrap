#ifndef WEBWRAP_PLATFORM_APPLE_WW_APPLE_HTTP_H
#define WEBWRAP_PLATFORM_APPLE_WW_APPLE_HTTP_H

#include <stddef.h>

#include "webwrap/webwrap.h"

int ww_apple_client_get(const char *url,
                        int *out_status_code,
                        char **out_body,
                        size_t *out_body_length,
                        ww_error_t *error);

#endif
