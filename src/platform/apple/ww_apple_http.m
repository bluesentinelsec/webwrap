#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>

#include "ww_apple_http.h"

struct ww_header_pair {
    char *name;
    char *value;
};

static void ww_error_set(ww_error_t *error, ww_error_type_t type, const char *value) {
    if (error == NULL) {
        return;
    }

    error->type = type;
    error->value = value;
    error->length = value == NULL ? 0U : strlen(value);
}

static char *ww_nsstring_dup(NSString *value) {
    NSData *utf8_data;
    size_t length;
    char *copy;

    if (value == nil) {
        return NULL;
    }

    utf8_data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (utf8_data == nil) {
        return NULL;
    }

    length = (size_t)[utf8_data length];
    copy = (char *)malloc(length + 1U);
    if (copy == NULL) {
        return NULL;
    }

    if (length > 0U) {
        memcpy(copy, [utf8_data bytes], length);
    }

    copy[length] = '\0';
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

static int ww_headers_from_dictionary(NSDictionary<id, id> *dictionary,
                                      struct ww_header_pair **out_headers,
                                      size_t *out_header_count,
                                      ww_error_t *error) {
    NSArray<id> *keys;
    struct ww_header_pair *headers;
    NSUInteger count;
    NSUInteger i;

    if (out_headers == NULL || out_header_count == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "response header outputs must be valid");
        return -1;
    }

    *out_headers = NULL;
    *out_header_count = 0U;
    if (dictionary == nil) {
        return 0;
    }

    keys = [dictionary allKeys];
    count = [keys count];
    headers = count == 0U ? NULL : (struct ww_header_pair *)calloc((size_t)count, sizeof(*headers));
    if (count > 0U && headers == NULL) {
        ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate response headers");
        return -1;
    }

    for (i = 0; i < count; ++i) {
        id key = keys[i];
        id value = dictionary[key];
        headers[i].name = ww_nsstring_dup([key description]);
        headers[i].value = ww_nsstring_dup([value description]);
        if (headers[i].name == NULL || headers[i].value == NULL) {
            ww_headers_free(headers, (size_t)count);
            ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to copy response headers");
            return -1;
        }
    }

    *out_headers = headers;
    *out_header_count = (size_t)count;
    return 0;
}

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
                         ww_error_t *error) {
    if (method == NULL || url == NULL || out_status_code == NULL || out_effective_url == NULL ||
        out_body == NULL || out_body_length == NULL || out_response_headers == NULL ||
        out_response_header_count == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "apple send requires valid inputs and outputs");
        return -1;
    }

    *out_status_code = 0;
    *out_effective_url = NULL;
    *out_body = NULL;
    *out_body_length = 0U;
    *out_response_headers = NULL;
    *out_response_header_count = 0U;

    @autoreleasepool {
        NSString *method_string = [NSString stringWithUTF8String:method];
        NSString *url_string = [NSString stringWithUTF8String:url];
        NSURL *ns_url = url_string == nil ? nil : [NSURL URLWithString:url_string];
        NSMutableURLRequest *request;
        NSURLResponse *response = nil;
        NSError *request_error = nil;
        NSData *response_data = nil;
        NSHTTPURLResponse *http_response;
        NSDictionary<id, id> *header_fields;
        char *effective_url;
        char *response_body;
        struct ww_header_pair *response_headers = NULL;
        size_t response_header_count = 0U;
        size_t response_length;
        size_t i;

        if (method_string == nil || ns_url == nil) {
            ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "request method or url is invalid");
            return -1;
        }

        request = [NSMutableURLRequest requestWithURL:ns_url];
        [request setHTTPMethod:method_string];
        if (body_length > 0U) {
            [request setHTTPBody:[NSData dataWithBytes:body length:body_length]];
        }

        for (i = 0; i < header_count; ++i) {
            NSString *name = [NSString stringWithUTF8String:headers[i].name];
            NSString *value = [NSString stringWithUTF8String:headers[i].value];
            if (name != nil && value != nil) {
                [request setValue:value forHTTPHeaderField:name];
            }
        }

        response_data = [NSURLConnection sendSynchronousRequest:request
                                             returningResponse:&response
                                                         error:&request_error];

        if (request_error != nil) {
            ww_error_set(error, WW_ERROR_REQUEST_FAILED, "native macOS request failed");
            return -1;
        }

        if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
            ww_error_set(error, WW_ERROR_REQUEST_FAILED, "response was not an HTTP response");
            return -1;
        }

        http_response = (NSHTTPURLResponse *)response;
        effective_url = ww_nsstring_dup([[http_response URL] absoluteString]);
        if (effective_url == NULL) {
            ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate effective url");
            return -1;
        }

        response_length = response_data == nil ? 0U : (size_t)[response_data length];
        response_body = (char *)malloc(response_length + 1U);
        if (response_body == NULL) {
            free(effective_url);
            ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate response body");
            return -1;
        }

        if (response_length > 0U) {
            memcpy(response_body, [response_data bytes], response_length);
        }

        response_body[response_length] = '\0';
        header_fields = [http_response allHeaderFields];
        if (ww_headers_from_dictionary(header_fields, &response_headers, &response_header_count, error) != 0) {
            free(effective_url);
            free(response_body);
            return -1;
        }

        *out_status_code = (int)[http_response statusCode];
        *out_effective_url = effective_url;
        *out_body = response_body;
        *out_body_length = response_length;
        *out_response_headers = response_headers;
        *out_response_header_count = response_header_count;
    }

    ww_error_clear(error);
    return 0;
}
