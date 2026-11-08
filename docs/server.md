# Server

`SpinelHTTP::Server.new(app, **options)` serves `app`, any object with
`call(req, res)`, usually an `SpinelHTTP::Router`. HTTP/1.1 and 1.0 over TCP:
keep-alive, chunked bodies, streaming. No TLS and no HTTP/2: put a proxy
in front for those (nginx, Caddy, a load balancer), which speaks HTTP/1.1
to it.

```ruby
SpinelHTTP::Server.new(routes, host: "0.0.0.0", port: 8080, max_body_bytes: 10_485_760).listen
```

## Options

| Option | Default | |
|---|---|---|
| `host:` | `"127.0.0.1"` | Address to listen on. |
| `port:` | `8080` | `0` picks a free one. |
| `observer:` | `nil` | Object with `finished(req, res)`, called after each response. `SpinelHTTP::AccessLog.new(io = $stdout)` prints `METHOD target status bytes`. |
| `errors:` | `SpinelHTTP::PlainErrors.new` | Object with `call(status, message, res)` that writes every error answer, the server's own included. |
| `idle_timeout:` | `5.0` | Seconds a keep-alive connection waits for its next request. |
| `header_timeout:` | `10.0` | Seconds to send a request head, and to take in one write of the response. |
| `shutdown_timeout:` | `10.0` | Seconds `listen` waits for requests in progress when stopping. |
| `max_header_bytes:` | `16384` | Request line and headers. Past it: 431. |
| `max_body_bytes:` | `1_048_576` | Request body. Past it: 413. |

A body also has to arrive at a minimum rate: `header_timeout` plus one
second per 64 KB received. Past it: 408.

## Methods

| | |
|---|---|
| `listen { \|port\| }` | Serves until `shutdown`, SIGTERM or SIGINT, then waits for the requests in progress (up to `shutdown_timeout`). Yields the bound port once listening. |
| `serve(socket)` | Serves one open connection until it closes. |
| `shutdown`, `stopping?` | Asks `listen` to stop; whether it was asked. |
| `port` | The bound port, once `listen` started. |

## Rules

- Each connection is served on its own thread, and the code reads as
  blocking code. In Spinel these are green threads, and one waiting on
  the network holds no system thread. State shared between requests
  needs a `Mutex`.
- The server owns the framing: it always computes `content-length` or
  `transfer-encoding`, and the app cannot set them.
- The parser refuses a request a proxy could read two ways, and closes:
  two lengths, a length beside `transfer-encoding: chunked`, a bare LF, a
  space before a colon.
- A watchdog thread checks the open connections every half second and
  closes the ones past a timeout. A waiting connection has no timer of
  its own.
- Each connection reuses its buffers, its request and its response for
  every request it carries.

## What the server answers by itself

| Status | When |
|---|---|
| 400 | Malformed request line or header, bare LF, missing or repeated `host`, both `content-length` and `transfer-encoding`, a repeated length, a malformed chunk. |
| 408 | The head or the body took too long. Closed without a grace period. |
| 413 | Body past `max_body_bytes`. |
| 417 | An `expect` other than `100-continue`. |
| 431 | Head past `max_header_bytes`. |
| 501 | Unknown method, or a transfer coding other than `chunked`. |
| 505 | A version other than HTTP/1.0 and 1.1. |

The connection closes after each of these. `expect: 100-continue` is
answered when the app first reads the body.

## Errors from the app

`SpinelHTTP::Error.new(status, message = reason)` raised anywhere answers that
status, the message as the body of the default error answer.
`SpinelHTTP::BadRequest` (400), `SpinelHTTP::Unauthorized` (401), `SpinelHTTP::NotFound`
(404) and `SpinelHTTP::MethodNotAllowed` (405) are the named ones. Any other
`StandardError` answers 500 and prints its class and message to stderr.
Once the head is on the wire nothing replaces the response: the
connection closes.

## Where it differs from Go's net/http

- No TLS and no HTTP/2 in the server.
- Timeouts are on by default, a minimum body rate included; Go's
  `Server` has none until they are set.
- Every refusal of a malformed request closes the connection.

## Tested by

`test/limits.rb`, `test/protocol.rb`, `test/keep_alive.rb`,
`test/idle.rb`, `test/errors.rb`.
