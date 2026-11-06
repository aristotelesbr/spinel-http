# http

An HTTP/1.1 server for [Spinel](https://github.com/matz/spinel), in plain
Ruby. It compiles to a native binary and also runs on CRuby.

## Start

```sh
spin new myapp && cd myapp
spin add http --path ../spinel-http-server   # where you cloned this repo
```

`bin/myapp.rb`:

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
spin run
curl "localhost:8080/?name=Ruby"   # Hello, Ruby!
```

## Handlers

A handler is any object with `call(req, res)`. A route can take
parameters: `routes.get "/posts/:id", ShowPost.new`, then
`req.param("id")`.

To run code before every route, add an object with `before(req, res)`.
Raising `HTTP::Unauthorized`, `HTTP::NotFound` and the like answers with
that status:

```ruby
class RequireToken
  def before(req, res)
    raise HTTP::Unauthorized unless req.header("authorization") == "Bearer secret"
  end
end

routes.use RequireToken.new
```

## Limits

Safe limits and timeouts are on by default. Change them on the server:

```ruby
HTTP::Server.new(routes, port: 8080, max_body_bytes: 10_485_760, idle_timeout: 30.0)
```

## License

MIT
