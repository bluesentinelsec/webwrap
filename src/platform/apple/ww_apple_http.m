#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>

#include "ww_apple_http.h"

static void ww_error_set(ww_error_t *error, ww_error_type_t type, const char *value) {
    if (error == NULL) {
        return;
    }

    error->type = type;
    error->value = value;
    error->length = value == NULL ? 0U : strlen(value);
}

int ww_apple_client_get(const char *url,
                        int *out_status_code,
                        char **out_body,
                        size_t *out_body_length,
                        ww_error_t *error) {
    if (url == NULL || out_status_code == NULL || out_body == NULL || out_body_length == NULL) {
        ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "apple get requires valid output pointers");
        return -1;
    }

    *out_status_code = 0;
    *out_body = NULL;
    *out_body_length = 0U;

    @autoreleasepool {
        NSString *url_string = [NSString stringWithUTF8String:url];
        NSURL *ns_url = url_string == nil ? nil : [NSURL URLWithString:url_string];

        if (ns_url == nil) {
            ww_error_set(error, WW_ERROR_INVALID_ARGUMENT, "url is invalid");
            return -1;
        }

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ns_url];
        NSURLResponse *response = nil;
        NSError *request_error = nil;
        NSData *response_data = nil;

        [request setHTTPMethod:@"GET"];
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

        NSHTTPURLResponse *http_response = (NSHTTPURLResponse *)response;
        size_t body_length = response_data == nil ? 0U : (size_t)[response_data length];
        char *body = (char *)malloc(body_length + 1U);
        if (body == NULL) {
            ww_error_set(error, WW_ERROR_OUT_OF_MEMORY, "failed to allocate response body");
            return -1;
        }

        if (body_length > 0U) {
            memcpy(body, [response_data bytes], body_length);
        }

        body[body_length] = '\0';
        *out_status_code = (int)[http_response statusCode];
        *out_body = body;
        *out_body_length = body_length;
    }

    ww_error_clear(error);
    return 0;
}
