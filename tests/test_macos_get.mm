#include <gtest/gtest.h>

#import <Foundation/Foundation.h>

extern "C" {
#include "webwrap/webwrap.h"
}

namespace {

static NSString *g_response_body = @"hello from mac";
static NSInteger g_response_status_code = 200;
static NSDictionary<NSString *, NSString *> *g_response_headers = nil;
static NSString *g_response_redirect_target = nil;
static NSTimeInterval g_response_delay_seconds = 0.0;
static NSString *g_last_method = nil;
static NSString *g_last_header_value = nil;
static NSString *g_last_body = nil;

}  // namespace

@interface WebWrapTestProtocol : NSURLProtocol
@end

@implementation WebWrapTestProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [request.URL.host hasSuffix:@"webwrap.test"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    g_last_method = [self.request.HTTPMethod copy];
    g_last_header_value = [[self.request valueForHTTPHeaderField:@"x-test-header"] copy];
    if (self.request.HTTPBody != nil) {
        g_last_body = [[NSString alloc] initWithData:self.request.HTTPBody encoding:NSUTF8StringEncoding];
    } else {
        g_last_body = nil;
    }

    if (g_response_delay_seconds > 0.0) {
        [self performSelector:@selector(finishLoadingResponse) withObject:nil afterDelay:g_response_delay_seconds];
        return;
    }

    [self finishLoadingResponse];
}

- (void)finishLoadingResponse {
    NSData *body_data;
    NSHTTPURLResponse *response;

    if (g_response_redirect_target != nil &&
        [self.request.URL.host isEqualToString:@"redirect.webwrap.test"]) {
        NSURL *redirect_url = [NSURL URLWithString:g_response_redirect_target];
        NSDictionary<NSString *, NSString *> *redirect_headers = @{
            @"Location" : g_response_redirect_target,
        };
        response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                               statusCode:g_response_status_code
                                              HTTPVersion:@"HTTP/1.1"
                                             headerFields:redirect_headers];
        [self.client URLProtocol:self
            wasRedirectedToRequest:[NSURLRequest requestWithURL:redirect_url]
                  redirectResponse:response];
        return;
    }

    body_data = [g_response_body dataUsingEncoding:NSUTF8StringEncoding];
    response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                           statusCode:g_response_status_code
                                          HTTPVersion:@"HTTP/1.1"
                                         headerFields:g_response_headers];

    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body_data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(finishLoadingResponse)
                                               object:nil];
}

@end

namespace {

class ScopedProtocolRegistration {
public:
    ScopedProtocolRegistration() {
        [NSURLProtocol registerClass:[WebWrapTestProtocol class]];
    }

    ~ScopedProtocolRegistration() {
        [NSURLProtocol unregisterClass:[WebWrapTestProtocol class]];
    }
};

static void ResetProtocolState(void) {
    g_response_body = @"hello from mac";
    g_response_status_code = 200;
    g_response_headers = @{
        @"Content-Type" : @"text/plain",
        @"Content-Length" : @"14",
        @"X-Test-Response" : @"response-value",
    };
    g_response_redirect_target = nil;
    g_response_delay_seconds = 0.0;
    g_last_method = nil;
    g_last_header_value = nil;
    g_last_body = nil;
}

}  // namespace

TEST(WebWrapMacTest, NativeGetFetchesRegisteredHttpResponse) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};

    ResetProtocolState();
    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_get(client, "http://webwrap.test/", &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);
    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    EXPECT_STREQ(ww_response_effective_url(response), "http://webwrap.test/");
    EXPECT_EQ(ww_response_body_length(response), 14U);
    EXPECT_STREQ(ww_response_body(response), "hello from mac");
    EXPECT_STREQ(ww_response_header_value(response, "content-type"), "text/plain");
    EXPECT_STREQ(ww_response_header_value(response, "x-test-response"), "response-value");
    EXPECT_EQ([g_last_method isEqualToString:@"GET"], YES);
    EXPECT_EQ(g_last_body, nil);

    ww_response_close(response);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativeSendPostsHeadersAndBody) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_request_t *request = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    static const char kBody[] = "{\"message\":\"hi\"}";

    ResetProtocolState();
    g_response_body = @"posted";
    g_response_status_code = 201;
    g_response_headers = @{
        @"Content-Type" : @"application/json",
        @"Content-Length" : @"6",
        @"Location" : @"/messages/42",
    };

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_request_open(&request, &error), 0);
    ASSERT_EQ(ww_request_set_method(request, "POST", &error), 0);
    ASSERT_EQ(ww_request_set_url(request, "http://webwrap.test/messages", &error), 0);
    ASSERT_EQ(ww_request_add_header(request, "x-test-header", "request-value", &error), 0);
    ASSERT_EQ(ww_request_add_header(request, "content-type", "application/json", &error), 0);
    ASSERT_EQ(ww_request_set_body(request, kBody, sizeof(kBody) - 1U, &error), 0);
    ASSERT_EQ(ww_client_send(client, request, &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);

    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 201);
    EXPECT_STREQ(ww_response_effective_url(response), "http://webwrap.test/messages");
    EXPECT_STREQ(ww_response_body(response), "posted");
    EXPECT_STREQ(ww_response_header_value(response, "location"), "/messages/42");
    EXPECT_EQ([g_last_method isEqualToString:@"POST"], YES);
    EXPECT_EQ([g_last_header_value isEqualToString:@"request-value"], YES);
    ASSERT_NE(g_last_body, nil);
    EXPECT_EQ([g_last_body isEqualToString:@"{\"message\":\"hi\"}"], YES);

    ww_response_close(response);
    ww_request_close(request);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativePostHelperSendsBody) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    static const char kBody[] = "post-body";

    ResetProtocolState();
    g_response_body = @"post ok";
    g_response_status_code = 201;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_post(client, "http://webwrap.test/post", kBody, sizeof(kBody) - 1U, &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);
    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 201);
    EXPECT_EQ([g_last_method isEqualToString:@"POST"], YES);
    ASSERT_NE(g_last_body, nil);
    EXPECT_EQ([g_last_body isEqualToString:@"post-body"], YES);

    ww_response_close(response);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativePutHelperSendsBody) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    static const char kBody[] = "put-body";

    ResetProtocolState();
    g_response_body = @"put ok";
    g_response_status_code = 200;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_put(client, "http://webwrap.test/put", kBody, sizeof(kBody) - 1U, &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);
    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    EXPECT_EQ([g_last_method isEqualToString:@"PUT"], YES);
    ASSERT_NE(g_last_body, nil);
    EXPECT_EQ([g_last_body isEqualToString:@"put-body"], YES);

    ww_response_close(response);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativeDeleteHelperSendsNoBody) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};

    ResetProtocolState();
    g_response_body = @"delete ok";
    g_response_status_code = 204;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_delete(client, "http://webwrap.test/delete", &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);
    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 204);
    EXPECT_EQ([g_last_method isEqualToString:@"DELETE"], YES);
    EXPECT_EQ(g_last_body, nil);

    ww_response_close(response);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativeGetFailsWhenRedirectLimitIsExceeded) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};

    ResetProtocolState();
    g_response_redirect_target = @"http://final.webwrap.test/landing";
    g_response_status_code = 302;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;
    options.max_redirects = 0;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    EXPECT_NE(ww_client_get(client, "http://redirect.webwrap.test/start", &response, &error), 0);
    EXPECT_EQ(response, nullptr);
    EXPECT_EQ(error.type, WW_ERROR_REDIRECT_LIMIT);

    ww_client_close(client);
}

TEST(WebWrapMacTest, NativeGetFailsOnTimeout) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};

    ResetProtocolState();
    g_response_delay_seconds = 0.2;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;
    options.request_timeout_ms = 20;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    EXPECT_NE(ww_client_get(client, "http://slow.webwrap.test/", &response, &error), 0);
    EXPECT_EQ(response, nullptr);
    EXPECT_EQ(error.type, WW_ERROR_TIMEOUT);

    ww_client_close(client);
}
