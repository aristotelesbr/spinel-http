# Response

The `res` a handler gets.

| | |
|---|---|
| `status=`, `status` | 200 by default. |
| `header(name, value)` | Adds a header. `ArgumentError` for a bad name, a value with CR or LF, or `content-length` / `transfer-encoding`, which are the server's. `connection: close` closes after this answer; a `date` replaces the server's. |
| `header_value(name)`, `header?(name)` | A header set so far. |
| `write(string)` | Appends to the body. |
| `write_int(integer)` | Appends the digits without building a String. |
| `text(string)` | `write`, plus `content-type: text/plain; charset=utf-8` when no type was set. |
| `flush` | Sends the head and what is buffered. Every later write streams, chunked. |
| `halt(status = status)` | Answers now with what was written. In a layer: the handler and the later befores are skipped. |
| `take` | Sends the head as it stands (a 101) and returns the socket, which the server no longer touches. |
| `sent?` | Whether the head is out. |
| `error` | The exception that became this response, or `nil`. |
| `bytes_written` | Body bytes written. |

## Rules

- A response goes out whole, with `content-length`, unless `flush` was
  called or the body passed 64 KB. Then it streams.
- 1xx, 204 and 304 carry no body: writes are dropped.
- After the head is out, `header` raises `IOError`, and an error closes
  the connection instead of answering.

## Error answers

Every error answer, the server's own included, goes through the
server's `errors:` object, `call(status, message, res)`:

```ruby
class JSONErrors
  def call(status, message, res)
    res.header("content-type", "application/json")
    res.write %({"status":#{status},"error":#{message.inspect}}\n)
  end
end

HTTP::Server.new(routes, errors: JSONErrors.new)
```

The default, `HTTP::PlainErrors`, writes the message as plain text.
`HTTP.reason(status)` gives the reason phrase (`"Not Found"`).

## Tested by

`test/response_body.rb`, `test/protocol.rb`, `test/errors.rb`.
