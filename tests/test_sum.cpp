#include <gtest/gtest.h>
#include <atomic>
#include <thread>
#include <vector>

extern "C" {
#include "webwrap/webwrap.h"
}

static ww_backend_t expected_default_client_backend(void) {
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

static ww_backend_t first_unavailable_backend(void) {
    const ww_backend_t candidates[] = {
        WW_BACKEND_CURL,
        WW_BACKEND_WINHTTP,
        WW_BACKEND_CFNETWORK,
        WW_BACKEND_FETCH,
    };

    for (ww_backend_t backend : candidates) {
        if (!ww_backend_is_available(backend)) {
            return backend;
        }
    }

    return WW_BACKEND_AUTO;
}

TEST(WebWrapTest, SumAddsTwoIntegers) {
    EXPECT_EQ(ww_sum(2, 3), 5);
}

TEST(WebWrapTest, SumHandlesNegativeValues) {
    EXPECT_EQ(ww_sum(-2, 3), 1);
}

TEST(WebWrapTest, ErrorClearResetsPublicFields) {
    ww_error_t error = {WW_ERROR_BACKEND_UNAVAILABLE, "boom", 4U};

    ww_error_clear(&error);

    EXPECT_EQ(error.type, WW_ERROR_NONE);
    EXPECT_EQ(error.value, nullptr);
    EXPECT_EQ(error.length, 0U);
}

TEST(WebWrapTest, DefaultClientBackendPrefersPlatformNative) {
    EXPECT_EQ(ww_default_client_backend(), expected_default_client_backend());
}

TEST(WebWrapTest, ClientOpenUsesDefaultBackendWhenAutoIsSelected) {
    ww_client_t *client = nullptr;
    ww_error_t error = {};

    ASSERT_EQ(ww_client_open(&client, nullptr, &error), 0);
    ASSERT_NE(client, nullptr);
    EXPECT_EQ(ww_client_backend(client), expected_default_client_backend());
    EXPECT_EQ(error.type, WW_ERROR_NONE);

    ww_client_close(client);
}

TEST(WebWrapTest, ClientOpenAllowsBuiltinOverride) {
    ww_client_t *client = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};

    ww_client_options_init(&options);
    options.backend = WW_BACKEND_BUILTIN;

    ASSERT_EQ(ww_client_open(&client, &options, &error), 0);
    ASSERT_NE(client, nullptr);
    EXPECT_EQ(ww_client_backend(client), WW_BACKEND_BUILTIN);

    ww_client_close(client);
}

TEST(WebWrapTest, ClientOpenRejectsUnavailableBackendOverride) {
    ww_client_t *client = nullptr;
    ww_client_options_t options;
    ww_error_t error = {};
    const ww_backend_t unavailable = first_unavailable_backend();

    if (unavailable == WW_BACKEND_AUTO) {
        GTEST_SKIP() << "all stub backends are available on this platform";
    }

    ww_client_options_init(&options);
    options.backend = unavailable;

    EXPECT_NE(ww_client_open(&client, &options, &error), 0);
    EXPECT_EQ(client, nullptr);
    EXPECT_EQ(error.type, WW_ERROR_BACKEND_UNAVAILABLE);
    EXPECT_EQ(error.length, std::char_traits<char>::length(error.value));
}

TEST(WebWrapTest, ServerOpenKeepsServerConfigurationSeparate) {
    ww_server_t *server = nullptr;
    ww_server_options_t options;
    ww_error_t error = {};

    ww_server_options_init(&options);
    options.backend = WW_BACKEND_BUILTIN;
    options.workers = 8;

    ASSERT_EQ(ww_server_open(&server, &options, &error), 0);
    ASSERT_NE(server, nullptr);
    EXPECT_EQ(ww_server_backend(server), WW_BACKEND_BUILTIN);
    EXPECT_EQ(ww_server_workers(server), 8U);

    ww_server_close(server);
}

TEST(WebWrapTest, ClientLifecycleIsSafeAcrossThreads) {
    constexpr int kThreadCount = 4;
    constexpr int kIterations = 64;
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;

    threads.reserve(kThreadCount);
    for (int i = 0; i < kThreadCount; ++i) {
        threads.emplace_back([&failures]() {
            for (int j = 0; j < kIterations; ++j) {
                ww_client_t *client = nullptr;
                ww_error_t error = {};

                if (ww_client_open(&client, nullptr, &error) != 0) {
                    ++failures;
                    continue;
                }

                if (ww_client_backend(client) != expected_default_client_backend()) {
                    ++failures;
                }

                ww_client_close(client);
            }
        });
    }

    for (std::thread &thread : threads) {
        thread.join();
    }

    EXPECT_EQ(failures.load(), 0);
}
