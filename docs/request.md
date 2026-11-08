# Request

The `req` a handler gets. Header names match without regard to case, and
an absent value reads as `""`, never `nil`.

| | |
|---|---|
| `method` | `"GET"`, `"POST"`... |
| `path` | Without the query: `"/posts/1"`. |
| `target` | As sent: `"/posts/1?x=1"`. |
| `query` | Without `?`; `""` when none. |
| `version` | `"HTTP/1.1"` or `"HTTP/1.0"`. |
| `param(name)` | A `:name` segment of the matched route, decoded ([router](router.md#patterns)). |
| `header(name)`, `header?(name)` | A header's value; whether it was sent. |
| `each_header { \|name, value\| }` | Every header, in order. |
| `content_length` | The declared length; `-1` for a chunked body. |
| `body` | The whole body, read on first use, up to `max_body_bytes`. |
| `each_chunk { \|piece\| }` | The body as it arrives. A piece is valid until the next one. |
| `query_params` | `SpinelHTTP::Params` of the query string. |
| `form_params` | `SpinelHTTP::Params` of an `application/x-www-form-urlencoded` body; empty for any other type. |
| `context`, `context=` | One object of the app's, for this request. |
| `started_at` | `SpinelHTTP.now` when the head had been read. |

## Params

```ruby
req.query_params["q"]            # "" when absent
req.query_params.int("page", 1)  # 1 when absent or empty; 400 when not a number
req.query_params.all("tag")      # ["a", "b"] for ?tag=a&tag=b
```

| `SpinelHTTP::Params` | |
|---|---|
| `new(string)` | Fields of a query string or urlencoded body. |
| `[name]` | The first value; `""` when absent. |
| `int(name, default)` | The first value as an Integer. Raises `SpinelHTTP::BadRequest` when it is not one. |
| `all(name)`, `key?(name)` | Every value, in order; whether the field is there. |
| `each { \|name, value\| }`, `size`, `empty?` | |

`+` decodes to a space and `%XX` to a byte. A bad escape, or more than
1000 fields, raises `SpinelHTTP::BadRequest`.

## Rules

- The request object is reused for the next request on the same
  connection. Keep the Strings it returns (each call returns a new one),
  not the object.
- The head is kept as offsets into the read buffer: a header becomes a
  String only when asked for, and so does a field.
- The body is not read until the app asks. A body the app leaves
  unread is read and dropped, up to 256 KB, before the next request on
  the connection; past that the connection closes.

## Tested by

`test/request_view.rb`, `test/request_body.rb`, `test/params.rb`.
