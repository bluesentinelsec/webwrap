# Web Wrap Design Doc

## Summary

Web Wrap is a cross-platform C library and CLI for HTTP client and server use cases. Its defining behavior is backend portability without forcing every application to ship and manage a heavyweight HTTP stack directly.

The proposed solution loads the best available platform backend at runtime:

- Windows: native Windows HTTP stack
- Linux: platform-native or system-available HTTP stack where practical, with the built-in implementation as the guaranteed fallback
- macOS: native Apple networking stack through an Objective-C shim
- Emscripten: browser-backed networking where possible

Web Wrap should ship a built-in C implementation for both client and server roles, starting with a minimal but portable subset and growing toward production-capable behavior. If no preferred platform backend is available, or if the caller explicitly requests it, Web Wrap falls back to the built-in implementation with explicit diagnostics. The user experience should make backend choice visible, predictable, and debuggable rather than "magic."

## Product Goals

- Give C developers one small API for common HTTP client and server workflows.
- Let CLI users test requests and stand up simple local servers without writing code.
- Prefer static linking for the library, while still allowing dynamic builds.
- Avoid hidden runtime behavior; initialization and backend selection must be inspectable.
- Work across Windows, Linux, macOS, and eventually Emscripten.
- Validate both HTTP and HTTPS behavior with unit and integration coverage.
- Favor a stable ABI from the start.
- Build with CMake and expose a high-level `Makefile` for common tasks.
- Document the public API with Doxygen.

## UX Principles

### 1. Start simple

The first successful use of Web Wrap should be obvious:

- CLI users should be able to make a request in one command.
- Library users should be able to perform a request in under 30 lines of C.
- Server startup should require only config plus one handler callback.

### 2. Be explicit about the backend

Every layer should answer:

- which backend was selected
- why that backend was selected
- what fallback behavior is in effect

This should be available via CLI output, library inspection APIs, and logs.

### 3. Fail openly

Initialization, TLS, binding, or backend loading failures must produce direct, actionable errors. Silent fallback is unacceptable if it changes security or protocol behavior.

### 4. Support both blocking and async paths in v1

The default API should still feel idiomatic in C, but v1 should also support non-blocking and multi-threaded workloads directly. The library should expose a simple blocking path for small tools and a first-class async path for applications that need concurrency, cancellation, or throughput.

### 5. Scale from tiny requests to huge transfers

The common path should be easy, but the design cannot assume small payloads. Callers should be able to buffer small bodies conveniently while also streaming multi-gigabyte downloads and uploads without hard-coded limits or wasteful copies.

## Primary User Workflows

### CLI user workflows

The CLI is for:

- quickly testing remote HTTP endpoints
- driving concurrent request workloads for debugging and smoke tests
- inspecting which backend Web Wrap would use
- running a lightweight local server for development or demos
- debugging TLS and header behavior

### Library user workflows

The C library is for:

- embedding an HTTP client in portable C applications
- embedding a small HTTP server with route handlers
- issuing concurrent requests without forcing each application to invent its own threading model
- using one stable API while platform backends differ underneath

## Proposed CLI UX

### Command shape

Proposed executable name: `webwrap`

Core commands:

- `webwrap get <url>`: simple GET request
- `webwrap request <method> <url>`: general-purpose request entry point
- `webwrap serve`: start an HTTP server from flags or a config file
- `webwrap backend list`: show available and selected backends
- `webwrap doctor`: validate runtime prerequisites and TLS support

This structure keeps the common case short while leaving room for diagnostic and server workflows.

### CLI design expectations

- Human-readable output by default
- `--json` for machine-readable output
- `--verbose` to show backend selection and network timing
- `--parallel` and worker-related flags for concurrent request execution
- backend override flags for testing and troubleshooting
- Exit codes that separate transport failure, TLS failure, config failure, and HTTP response status handling
- `--fail-on-http-error` to treat HTTP `4xx/5xx` as command failure when desired

### CLI examples

#### Inspect backend selection

```sh
$ webwrap backend list
Selected backend: winhttp
Reason: native backend available on this platform

Available backends:
  - winhttp      available
  - builtin      available
  - curl         unavailable on this platform
```

```sh
$ webwrap doctor --verbose
Platform: macOS
Selected client backend: cfnetwork
Selected server backend: builtin
TLS support: enabled
HTTP/2 support: backend-dependent
Fallback active: no
```

```sh
$ webwrap get https://api.example.com/health --backend builtin
Backend override: builtin
HTTP/1.1 200 OK

{"status":"ok"}
```

#### Basic client request

```sh
$ webwrap get https://api.example.com/health
HTTP/1.1 200 OK
content-type: application/json
content-length: 17

{"status":"ok"}
```

#### JSON POST request

```sh
$ webwrap request POST https://api.example.com/v1/messages \
    --header "content-type: application/json" \
    --body '{"message":"hello"}' \
    --show-backend
Backend: curl
HTTP/1.1 201 Created
location: /v1/messages/42

{"id":42,"message":"hello"}
```

#### Run concurrent client requests

```sh
$ webwrap get https://api.example.com/health --parallel 8 --repeat 100 --stats
Backend: curl
Requests: 100
Concurrency: 8
HTTP 200 responses: 100
Latency p50: 18ms
Latency p95: 41ms
Latency p99: 57ms
```

#### Save response body to a file

```sh
$ webwrap get https://example.com/archive.tar.gz --output archive.tar.gz
Saved body to archive.tar.gz
Status: 200 OK
Backend: builtin
```

#### Fail fast on TLS problems

```sh
$ webwrap get https://localhost:8443 --ca-file ./dev-ca.pem --fail-on-http-error
TLS validation failed: certificate is not trusted by the selected backend
```

#### Start a local development server

```sh
$ webwrap serve --listen 127.0.0.1:8080 --root ./public --workers 4
Listening on http://127.0.0.1:8080
Backend: builtin
Workers: 4
Routes:
  GET / -> ./public/index.html
  GET /assets/* -> ./public/assets/*
```

#### Start a JSON echo server from inline routes

```sh
$ webwrap serve --listen 127.0.0.1:8080 \
    --route "GET /health => json:{\"status\":\"ok\"}" \
    --route "POST /echo => echo"
Listening on http://127.0.0.1:8080
```

## Proposed Library UX

The library should expose:

- a small initialization surface
- a client API for request/response workflows
- an async client API for concurrent request execution
- streaming upload and download APIs for large bodies
- a server API for binding routes and returning responses
- server concurrency controls
- backend inspection APIs
- structured error reporting

The API should feel like C, not like a direct translation of a C++ builder pattern. Value structs plus explicit init/free pairs are preferred. Blocking and async entry points should share the same request/response model so users do not need to learn two unrelated APIs. Client and server runtime objects should stay separate even if they share a common process-wide context for backend discovery and configuration.

## Proposed C API Sketch

The names below are illustrative and intended to make the user experience concrete.

### Core types

```c
typedef struct ww_context ww_context_t;
typedef struct ww_client ww_client_t;
typedef struct ww_server ww_server_t;
typedef struct ww_request ww_request_t;
typedef struct ww_response ww_response_t;
typedef struct ww_error ww_error_t;
typedef struct ww_future ww_future_t;
typedef struct ww_executor ww_executor_t;
typedef struct ww_incoming_request ww_incoming_request_t;
typedef struct ww_outgoing_response ww_outgoing_response_t;

typedef enum ww_backend_kind {
    WW_BACKEND_NONE = 0,
    WW_BACKEND_BUILTIN,
    WW_BACKEND_CURL,
    WW_BACKEND_WINHTTP,
    WW_BACKEND_CFNETWORK
} ww_backend_kind_t;
```

### Core lifecycle

```c
int ww_init(ww_context_t **out_ctx, const ww_init_options_t *options, ww_error_t *err);
void ww_shutdown(ww_context_t *ctx);

ww_backend_kind_t ww_client_backend(const ww_context_t *ctx);
ww_backend_kind_t ww_server_backend(const ww_context_t *ctx);
const char *ww_backend_name(ww_backend_kind_t kind);
int ww_error_code(const ww_error_t *err);
int ww_error_type(const ww_error_t *err);
const char *ww_error_message(const ww_error_t *err);
size_t ww_error_message_len(const ww_error_t *err);
int ww_executor_open(ww_context_t *ctx, ww_executor_t **out_exec, const ww_executor_options_t *options, ww_error_t *err);
void ww_executor_close(ww_executor_t *exec);
```

### Client workflow API

```c
void ww_request_init(ww_request_t *req);
void ww_request_set_method(ww_request_t *req, const char *method);
void ww_request_set_url(ww_request_t *req, const char *url);
int ww_request_add_header(ww_request_t *req, const char *name, const char *value);
int ww_request_set_body(ww_request_t *req, const void *data, size_t len, const char *content_type);
void ww_request_free(ww_request_t *req);

int ww_client_open(ww_context_t *ctx, ww_client_t **out_client, const ww_client_options_t *options, ww_error_t *err);
int ww_client_send(ww_client_t *client, const ww_request_t *req, ww_response_t *resp, ww_error_t *err);
int ww_client_send_async(ww_client_t *client, ww_executor_t *exec, const ww_request_t *req, ww_future_t **out_future, ww_error_t *err);
int ww_client_download(ww_client_t *client, const ww_request_t *req, ww_write_stream_t *stream, ww_response_t *resp, ww_error_t *err);
void ww_client_close(ww_client_t *client);

void ww_response_init(ww_response_t *resp);
int ww_response_status(const ww_response_t *resp);
const void *ww_response_body(const ww_response_t *resp, size_t *out_len);
void ww_response_free(ww_response_t *resp);

int ww_future_wait(ww_future_t *future, ww_response_t *resp, ww_error_t *err);
int ww_future_poll(ww_future_t *future, int *out_ready, ww_error_t *err);
int ww_future_cancel(ww_future_t *future, ww_error_t *err);
void ww_future_close(ww_future_t *future);

int ww_request_set_read_stream(ww_request_t *req, ww_read_stream_t *stream, const char *content_type);
```

### Server workflow API

```c
typedef int (*ww_handler_fn)(const ww_incoming_request_t *req, ww_outgoing_response_t *resp, void *user_data);

int ww_server_open(ww_context_t *ctx, ww_server_t **out_server, const ww_server_options_t *options, ww_error_t *err);
int ww_server_route(ww_server_t *server, const char *method, const char *path, ww_handler_fn handler, void *user_data, ww_error_t *err);
int ww_server_listen(ww_server_t *server, const char *bind_addr, ww_error_t *err);
int ww_server_set_workers(ww_server_t *server, unsigned workers, ww_error_t *err);
int ww_server_serve_files(ww_server_t *server, const char *url_prefix, const char *filesystem_root, ww_error_t *err);
void ww_server_close(ww_server_t *server);

const void *ww_request_body(const ww_incoming_request_t *req, size_t *out_len);

int ww_response_set_status(ww_outgoing_response_t *resp, int status_code);
int ww_response_add_header(ww_outgoing_response_t *resp, const char *name, const char *value);
int ww_response_set_body(ww_outgoing_response_t *resp, const void *data, size_t len);
int ww_response_set_text(ww_outgoing_response_t *resp, const char *body);
int ww_response_set_json(ww_outgoing_response_t *resp, const char *json_text);
```

## C Library Examples

### Client example

This shows the "smallest useful" client flow: init, inspect backend, send request, read response, clean up.

```c
#include <stdio.h>
#include "webwrap/webwrap.h"

int main(void) {
    ww_context_t *ctx = NULL;
    ww_client_t *client = NULL;
    ww_request_t req;
    ww_response_t resp;
    ww_error_t err;

    if (ww_init(&ctx, NULL, &err) != 0) {
        fprintf(stderr, "webwrap init failed: %s\n", ww_error_message(&err));
        return 1;
    }

    printf("client backend: %s\n", ww_backend_name(ww_client_backend(ctx)));

    if (ww_client_open(ctx, &client, NULL, &err) != 0) {
        fprintf(stderr, "client open failed: %s\n", ww_error_message(&err));
        ww_shutdown(ctx);
        return 1;
    }

    ww_request_init(&req);
    ww_response_init(&resp);

    ww_request_set_method(&req, "GET");
    ww_request_set_url(&req, "https://api.example.com/health");
    ww_request_add_header(&req, "accept", "application/json");

    if (ww_client_send(client, &req, &resp, &err) != 0) {
        fprintf(stderr, "request failed: %s\n", ww_error_message(&err));
        ww_request_free(&req);
        ww_response_free(&resp);
        ww_client_close(client);
        ww_shutdown(ctx);
        return 1;
    }

    size_t body_len = 0;
    const void *body = ww_response_body(&resp, &body_len);

    printf("status: %d\n", ww_response_status(&resp));
    fwrite(body, 1, body_len, stdout);
    fputc('\n', stdout);

    ww_request_free(&req);
    ww_response_free(&resp);
    ww_client_close(client);
    ww_shutdown(ctx);
    return 0;
}
```

### Async client example

This shows a v1 async flow using a shared executor and multiple in-flight requests.

```c
#include <stdio.h>
#include "webwrap/webwrap.h"

int main(void) {
    ww_context_t *ctx = NULL;
    ww_client_t *client = NULL;
    ww_executor_t *exec = NULL;
    ww_request_t req_a;
    ww_request_t req_b;
    ww_response_t resp;
    ww_future_t *future_a = NULL;
    ww_future_t *future_b = NULL;
    ww_error_t err;

    if (ww_init(&ctx, NULL, &err) != 0) {
        fprintf(stderr, "webwrap init failed: %s\n", ww_error_message(&err));
        return 1;
    }

    if (ww_executor_open(ctx, &exec, NULL, &err) != 0) {
        fprintf(stderr, "executor open failed: %s\n", ww_error_message(&err));
        ww_shutdown(ctx);
        return 1;
    }

    if (ww_client_open(ctx, &client, NULL, &err) != 0) {
        fprintf(stderr, "client open failed: %s\n", ww_error_message(&err));
        ww_executor_close(exec);
        ww_shutdown(ctx);
        return 1;
    }

    ww_request_init(&req_a);
    ww_request_init(&req_b);
    ww_request_set_method(&req_a, "GET");
    ww_request_set_method(&req_b, "GET");
    ww_request_set_url(&req_a, "https://api.example.com/a");
    ww_request_set_url(&req_b, "https://api.example.com/b");

    if (ww_client_send_async(client, exec, &req_a, &future_a, &err) != 0 ||
        ww_client_send_async(client, exec, &req_b, &future_b, &err) != 0) {
        fprintf(stderr, "async send failed: %s\n", ww_error_message(&err));
        ww_request_free(&req_a);
        ww_request_free(&req_b);
        ww_client_close(client);
        ww_executor_close(exec);
        ww_shutdown(ctx);
        return 1;
    }

    ww_response_init(&resp);
    if (ww_future_wait(future_a, &resp, &err) != 0) {
        fprintf(stderr, "request a failed: %s\n", ww_error_message(&err));
    } else {
        printf("request a status: %d\n", ww_response_status(&resp));
        ww_response_free(&resp);
    }

    ww_response_init(&resp);
    if (ww_future_wait(future_b, &resp, &err) != 0) {
        fprintf(stderr, "request b failed: %s\n", ww_error_message(&err));
    } else {
        printf("request b status: %d\n", ww_response_status(&resp));
        ww_response_free(&resp);
    }

    ww_future_close(future_a);
    ww_future_close(future_b);
    ww_request_free(&req_a);
    ww_request_free(&req_b);
    ww_client_close(client);
    ww_executor_close(exec);
    ww_shutdown(ctx);
    return 0;
}
```

### Server example

This shows a multi-worker server with two routes and a handler callback.

```c
#include <stdio.h>
#include "webwrap/webwrap.h"

static int handle_health(const ww_incoming_request_t *req,
                         ww_outgoing_response_t *resp,
                         void *user_data) {
    (void)req;
    (void)user_data;

    ww_response_set_status(resp, 200);
    ww_response_add_header(resp, "content-type", "application/json");
    ww_response_set_json(resp, "{\"status\":\"ok\"}");
    return 0;
}

static int handle_echo(const ww_incoming_request_t *req,
                       ww_outgoing_response_t *resp,
                       void *user_data) {
    size_t body_len = 0;
    const void *body = ww_request_body(req, &body_len);

    (void)user_data;

    ww_response_set_status(resp, 200);
    ww_response_add_header(resp, "content-type", "application/octet-stream");
    ww_response_set_body(resp, body, body_len);
    return 0;
}

int main(void) {
    ww_context_t *ctx = NULL;
    ww_server_t *server = NULL;
    ww_error_t err;

    if (ww_init(&ctx, NULL, &err) != 0) {
        fprintf(stderr, "webwrap init failed: %s\n", ww_error_message(&err));
        return 1;
    }

    printf("server backend: %s\n", ww_backend_name(ww_server_backend(ctx)));

    if (ww_server_open(ctx, &server, NULL, &err) != 0) {
        fprintf(stderr, "server open failed: %s\n", ww_error_message(&err));
        ww_shutdown(ctx);
        return 1;
    }

    if (ww_server_set_workers(server, 4, &err) != 0) {
        fprintf(stderr, "worker configuration failed: %s\n", ww_error_message(&err));
        ww_server_close(server);
        ww_shutdown(ctx);
        return 1;
    }

    if (ww_server_route(server, "GET", "/health", handle_health, NULL, &err) != 0) {
        fprintf(stderr, "route registration failed: %s\n", ww_error_message(&err));
        ww_server_close(server);
        ww_shutdown(ctx);
        return 1;
    }

    if (ww_server_route(server, "POST", "/echo", handle_echo, NULL, &err) != 0) {
        fprintf(stderr, "route registration failed: %s\n", ww_error_message(&err));
        ww_server_close(server);
        ww_shutdown(ctx);
        return 1;
    }

    if (ww_server_listen(server, "127.0.0.1:8080", &err) != 0) {
        fprintf(stderr, "listen failed: %s\n", ww_error_message(&err));
        ww_server_close(server);
        ww_shutdown(ctx);
        return 1;
    }

    ww_server_close(server);
    ww_shutdown(ctx);
    return 0;
}
```

## Expected User Experience

### Initialization

Initialization should be explicit and cheap. Users should not have to guess whether backend probing already happened or whether TLS support is available. `ww_init()` should establish global configuration and discovery state, while optional runtime pieces should be lazily loaded on first use. When a lazy load fails, the failure should be immediate and explicit at the operation boundary with an actionable error.

### Backend visibility

Both CLI and library users should be able to inspect:

- selected backend
- fallback state
- backend capabilities, such as TLS, concurrency support, and possibly HTTP/2

### Error reporting

Errors should separate these cases clearly:

- backend load failure
- unsupported feature on current backend
- DNS/connectivity failure
- TLS verification failure
- malformed request configuration
- async cancellation or executor shutdown failure
- server bind/listen failure

Structured errors should expose at least:

- error code
- error type/category
- message pointer
- message length

The CLI should print the short message and optionally a more detailed diagnostic trace. Errors should be phrased to help recovery, for example: "expected native backend, received unavailable backend, try builtin."

### Configuration

The default configuration should be minimal, but advanced cases should remain possible:

- timeout settings
- CA bundle or trust configuration
- redirect policy
- executor sizing and queue limits
- bind address and port
- worker count and concurrency model
- backend override or backend preference
- request/response header access
- streamed request/response bodies
- body size limits for servers

## Design Notes

- Use highly portable C.
- Target a modern standard such as C23 if toolchain support is acceptable, otherwise C17.
- Validate with unit and integration tests and follow test-driven development where practical.
- Ship CI/CD support for Windows, Linux, and macOS.
- Plan for Emscripten support early, but avoid polluting the core API with browser-only abstractions.
- Offer both a CLI tool and an idiomatic shared/static library.
- Support async client workflows and multi-threaded server execution in v1.
- Use CMake as the primary build system.
- Configure CMake to emit `compile_commands.json` for editor and LSP support.
- Use Doxygen for public API documentation.
- Provide a top-level `Makefile` for common developer tasks.
- Make static linking the default.
- Support dynamic libraries as a build option.
- Test both HTTP and HTTPS behavior.
- Fail transparently on initialization or capability detection failures.
- Keep business logic in the library; the CLI should be a thin front end over the same public library surface.
- Favor SDL- and curl-like C conventions for namespacing, project organization, and error handling.
- Avoid hard-coded buffers; prefer dynamic allocation sized to actual workload.
- Use centralized cleanup patterns, including `goto`-based error handling where it improves correctness and clarity.

## Design Direction

### Backend strategy

- The built-in implementation should support both client and server roles.
- The built-in implementation can start as a minimal portable subset, but the target is production-capable behavior over time.
- Web Wrap should prefer native backends when available and fall back to the built-in implementation when needed.
- macOS native support should use an Objective-C shim, and the build system should explicitly accommodate mixed C and Objective-C sources.
- Callers should be able to force backend selection through init options and CLI flags to support testing and troubleshooting.

### API scope

- Favor the simplest async model for the caller. v1 should standardize on a future-and-executor model because it keeps the call site simple and lets callers fire requests without reasoning about callbacks or event-loop internals.
- Streaming upload and download should be first-class features in v1; buffering alone is not sufficient for very large payloads.
- Typed helper APIs should focus on the needs of the majority of callers. The target is to cover the common 90% of header, TLS, and request configuration use cases while retaining raw access for everything else.
- Client and server runtime objects should remain separate if that keeps the implementation easier to reason about.

### Server model

- The built-in server should aim to be production-capable, not development-only.
- Static file serving is an expected feature and should exist in the library API as well as the CLI.
- Server concurrency should be exposed through a portable abstraction that is easy for the caller to use, even if backend internals differ. The implementation should align with the executor-oriented model rather than forcing callers to manage a raw event loop.

### TLS and security

- Prefer the platform trust store when available, with a consistent cross-platform CA bundle fallback story.
- The default TLS experience should be nearly invisible to the caller; secure defaults matter more than exposing every knob.
- If a requested security feature is unavailable on the selected backend, the library should return a structured error. The CLI should fail hard and suggest an alternative backend when appropriate.

### Emscripten support

- Client support is the minimum requirement under Emscripten, but experimental server support is worth exploring.
- The public API should remain as identical as practical across platforms, with capability differences documented rather than split into a different programming model.
- The abstraction should stay focused on callers who need HTTP/S support without taking on backend packaging complexity themselves.

### Packaging and runtime behavior

- Favor lazy loading for optional backend dependencies, but fail immediately and clearly when the caller invokes unavailable functionality.
- All business logic should live in the library. The CLI should be a thin wrapper over the same implementation.
- Favor a stable ABI from the start.
- The first stable release should not ship until the built-in client and server can support the promised public API surface end-to-end.
