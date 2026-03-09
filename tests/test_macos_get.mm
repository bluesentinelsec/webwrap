#include <gtest/gtest.h>

#import <Foundation/Foundation.h>

extern "C" {
#include "webwrap/webwrap.h"
}

@interface WebWrapTestProtocol : NSURLProtocol
@end

@implementation WebWrapTestProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [request.URL.host isEqualToString:@"webwrap.test"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSData *body = [@"hello from mac" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                    statusCode:200
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:@{
                                      @"Content-Type" : @"text/plain",
                                      @"Content-Length" : @"14",
                                  }];

    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
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

}  // namespace

TEST(WebWrapMacTest, NativeGetFetchesRegisteredHttpResponse) {
    ScopedProtocolRegistration protocol_registration;
    ww_client_t *client = nullptr;
    ww_response_t *response = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_CFNETWORK;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_EQ(ww_client_get(client, "http://webwrap.test/", &response, &error), 0)
        << (error.value == nullptr ? "" : error.value);
    ASSERT_NE(response, nullptr);
    EXPECT_EQ(ww_response_status_code(response), 200);
    EXPECT_EQ(ww_response_body_length(response), 14U);
    EXPECT_STREQ(ww_response_body(response), "hello from mac");

    ww_response_close(response);
    ww_client_close(client);
}
