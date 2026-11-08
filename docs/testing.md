# Testing

`require "http/testing"` sends requests through a loopback socket and the
real server, so a test meets the same parser and limits as production.

```ruby
res = HTTP::Testing.request(app, "POST /notes", headers: { "authorization" => "Bearer t" }, body: "text=hi")
res.status          # 201
res.header("allow") # "" when absent
res.body

HTTP::Testing.raw(app, "GET / HTTP/1.1\r\nhost: x\r\ncontent-length: 1\r\ncontent-length: 2\r\n\r\n")
# => "HTTP/1.1 400 Bad Request\r\n..."
```

| | |
|---|---|
| `request(app, "VERB /path", headers: {}, body: "", server: nil)` | One request. The result has `status`, `headers` (a Hash, lowercase names), `body` and `header(name)`. |
| `raw(app, bytes, server: nil)` | The bytes as they are, any number of requests; returns everything the server wrote until it closed. |

`server:` takes an `HTTP::Server` with the options under test
(`errors:`, limits).

## Running the tests

`spin test` compiles each `test/*.rb` and compares what it prints with
`test/*.rb.expected`, which is what CRuby prints for the same file. The
package is plain Ruby, so CRuby is the oracle.
