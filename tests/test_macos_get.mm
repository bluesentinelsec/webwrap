#include <gtest/gtest.h>
#include <cstring>
#include <string>

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
static NSArray<NSData *> *g_response_chunks = nil;
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
    NSMutableData *streamed_body;

    g_last_method = [self.request.HTTPMethod copy];
    g_last_header_value = [[self.request valueForHTTPHeaderField:@"x-test-header"] copy];
    if (self.request.HTTPBody != nil) {
        g_last_body = [[NSString alloc] initWithData:self.request.HTTPBody encoding:NSUTF8StringEncoding];
    } else if (self.request.HTTPBodyStream != nil) {
        uint8_t buffer[1024];
        NSInteger bytes_read;

        streamed_body = [[NSMutableData alloc] init];
        [self.request.HTTPBodyStream open];
        for (;;) {
            bytes_read = [self.request.HTTPBodyStream read:buffer maxLength:sizeof(buffer)];
            if (bytes_read <= 0) {
                break;
            }

            [streamed_body appendBytes:buffer length:(NSUInteger)bytes_read];
        }

        [self.request.HTTPBodyStream close];
        g_last_body = [[NSString alloc] initWithData:streamed_body encoding:NSUTF8StringEncoding];
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
        NSDictionary<NSString *, NSString *> *redirect_headers = @{
            @"Location" : g_response_redirect_target,
        };
        response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                               statusCode:g_response_status_code
                                              HTTPVersion:@"HTTP/1.1"
                                             headerFields:redirect_headers];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }

    response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                           statusCode:g_response_status_code
                                          HTTPVersion:@"HTTP/1.1"
                                         headerFields:g_response_headers];

    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (g_response_chunks != nil) {
        for (NSData *chunk : g_response_chunks) {
            [self.client URLProtocol:self didLoadData:chunk];
        }
    } else {
        body_data = [g_response_body dataUsingEncoding:NSUTF8StringEncoding];
        [self.client URLProtocol:self didLoadData:body_data];
    }

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
    g_response_chunks = nil;
    g_last_method = nil;
    g_last_header_value = nil;
    g_last_body = nil;
}

static NSString *TemporaryTestPath(NSString *name) {
    NSString *identifier = [[NSUUID UUID] UUIDString];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"webwrap-%@-%@", name, identifier]];
}

struct ReaderState {
    const char *body;
    size_t length;
    size_t offset;
    size_t chunk_size;
};

static int ReadBodyChunk(void *user_data,
                         void *buffer,
                         size_t buffer_capacity,
                         size_t *out_bytes_read,
                         ww_error_t *error) {
    ReaderState *state = static_cast<ReaderState *>(user_data);
    size_t remaining;
    size_t bytes_to_copy;

    if (state == nullptr || buffer == nullptr || out_bytes_read == nullptr) {
        if (error != nullptr) {
            error->type = WW_ERROR_INVALID_ARGUMENT;
            error->value = "invalid body reader state";
            error->length = std::strlen(error->value);
        }

        return -1;
    }

    remaining = state->length - state->offset;
    if (remaining == 0U) {
        *out_bytes_read = 0U;
        return 0;
    }

    bytes_to_copy = state->chunk_size;
    if (bytes_to_copy > remaining) {
        bytes_to_copy = remaining;
    }

    if (bytes_to_copy > buffer_capacity) {
        bytes_to_copy = buffer_capacity;
    }

    std::memcpy(buffer, state->body + state->offset, bytes_to_copy);
    state->offset += bytes_to_copy;
    *out_bytes_read = bytes_to_copy;
    return 0;
}

struct WriterState {
    std::string body;
};

static int WriteBodyChunk(void *user_data, const void *buffer, size_t buffer_length, ww_error_t *error) {
    WriterState *state = static_cast<WriterState *>(user_data);

    if (state == nullptr || (buffer == nullptr && buffer_length > 0U)) {
        if (error != nullptr) {
            error->type = WW_ERROR_INVALID_ARGUMENT;
            error->value = "invalid body writer state";
            error->length = std::strlen(error->value);
        }

        return -1;
    }

    state->body.append(static_cast<const char *>(buffer), buffer_length);
    return 0;
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

TEST(WebWrapMacTest, NativeSendStreamsRequestBodyFromReader) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_request_t *request = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    const char kBody[] = "streamed-request-body";
    ReaderState reader_state = {kBody, sizeof(kBody) - 1U, 0U, 5U};

    ResetProtocolState();
    g_response_body = @"streamed ok";
    g_response_status_code = 200;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_request_open(&request, &error), 0);
    ASSERT_EQ(ww_request_set_method(request, "POST", &error), 0);
    ASSERT_EQ(ww_request_set_url(request, "http://webwrap.test/stream-upload", &error), 0);
    ASSERT_EQ(ww_request_set_body_reader(request, ReadBodyChunk, &reader_state, &error), 0);
    ASSERT_EQ(ww_client_send(client, request, &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);

    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    ASSERT_NE(g_last_body, nil);
    EXPECT_EQ([g_last_body isEqualToString:@"streamed-request-body"], YES);
    EXPECT_EQ(reader_state.offset, sizeof(kBody) - 1U);

    ww_response_close(response);
    ww_request_close(request);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativePutFileStreamsUploadBody) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    NSString *path = TemporaryTestPath(@"upload.txt");
    NSError *write_error = nil;

    ASSERT_TRUE([@"file-upload-body" writeToFile:path
                                      atomically:YES
                                        encoding:NSUTF8StringEncoding
                                           error:&write_error]);

    ResetProtocolState();
    g_response_body = @"uploaded";
    g_response_status_code = 200;

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_put_file(client, "http://webwrap.test/file-upload", [path fileSystemRepresentation], &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);

    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    ASSERT_NE(g_last_body, nil);
    EXPECT_EQ([g_last_body isEqualToString:@"file-upload-body"], YES);

    ww_response_close(response);
    ww_client_close(client);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
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

TEST(WebWrapMacTest, NativeGetStreamsResponseBodyToWriter) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    WriterState writer_state;

    ResetProtocolState();
    g_response_status_code = 200;
    g_response_chunks = @[
        [@"hello " dataUsingEncoding:NSUTF8StringEncoding],
        [@"from " dataUsingEncoding:NSUTF8StringEncoding],
        [@"chunks" dataUsingEncoding:NSUTF8StringEncoding],
    ];
    g_response_headers = @{
        @"Content-Type" : @"text/plain",
        @"X-Test-Response" : @"streamed",
    };

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_get_to_writer(client, "http://webwrap.test/stream-download", WriteBodyChunk, &writer_state, &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);

    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    EXPECT_EQ(writer_state.body, "hello from chunks");
    EXPECT_EQ(ww_response_body_length(response), 0U);
    EXPECT_STREQ(ww_response_body(response), "");
    EXPECT_STREQ(ww_response_header_value(response, "x-test-response"), "streamed");

    ww_response_close(response);
    ww_client_close(client);
}

TEST(WebWrapMacTest, NativeGetStreamsResponseBodyToFile) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    NSString *path = TemporaryTestPath(@"download.txt");
    NSString *downloaded = nil;

    ResetProtocolState();
    g_response_status_code = 200;
    g_response_chunks = @[
        [@"huge " dataUsingEncoding:NSUTF8StringEncoding],
        [@"file " dataUsingEncoding:NSUTF8StringEncoding],
        [@"download" dataUsingEncoding:NSUTF8StringEncoding],
    ];

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_get_to_file(client, "http://webwrap.test/large-download", [path fileSystemRepresentation], &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);

    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    downloaded = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    ASSERT_NE(downloaded, nil);
    EXPECT_EQ([downloaded isEqualToString:@"huge file download"], YES);

    ww_response_close(response);
    ww_client_close(client);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}

TEST(WebWrapMacTest, NativeGetReturnsRedirectResponseInProtocolHarness) {
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

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_get(client, "http://redirect.webwrap.test/start", &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);
    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 302);
    EXPECT_STREQ(ww_response_effective_url(response), "http://redirect.webwrap.test/start");

    ww_response_close(response);
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
