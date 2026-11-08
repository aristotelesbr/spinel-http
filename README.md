# http

An HTTP/1.1 server for [Spinel](https://github.com/matz/spinel), in plain
Ruby. It compiles to a native binary, and the same code runs on CRuby,
which its tests use as the oracle.

```ruby
require "http/server"

class Hello
  def call(req, res)
    res.text "Hello, #{req.query_params["name"]}!\n"
  end
end

routes = HTTP::Router.new
routes.get "/", Hello.new

HTTP::Server.new(routes, port: 8080).listen
```

```sh
spin new myapp && cd myapp
spin add http --path ../spinel-http-server   # where you cloned this repo
spin run                                     # with the code above in bin/myapp.rb
curl "localhost:8080/?name=Ruby"             # Hello, Ruby!
```

## What it does

- HTTP/1.1 and 1.0: keep-alive, chunked bodies both ways, streaming,
  `expect: 100-continue`, `HEAD`, `OPTIONS`.
- One green thread per connection, code written as blocking code.
- A router with `:params`, namespaces, and layers that run `before` and
  `after` a handler.
- Limits and timeouts on by default; a strict parser that refuses an
  ambiguous request and closes.
- `HTTP::Testing`, which sends requests through the real server.

## What it does not do

- TLS and HTTP/2: put a proxy in front.
- Subtree patterns (`/static/...`) and redirects for a cleaned path or a
  trailing slash.
- A block DSL (`get "/" do ... end`): handlers are objects, see
  [DECISIONS.md](DECISIONS.md).

## Docs

| | |
|---|---|
| [docs/server.md](docs/server.md) | Options, limits, what the server answers by itself, errors. |
| [docs/router.md](docs/router.md) | Patterns, precedence, layers, what is refused, differences from Go's ServeMux. |
| [docs/request.md](docs/request.md) | The request, its params and its body. |
| [docs/response.md](docs/response.md) | Writing, streaming, error answers. |
| [docs/testing.md](docs/testing.md) | `HTTP::Testing` and `spin test`. |
| [DECISIONS.md](DECISIONS.md) | What was chosen, refused and left out, and why. |
| [examples/](examples/) | `hello.rb`; `notes.rb`, a small service with a token. |

## License

MIT
