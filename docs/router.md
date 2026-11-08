# Router

`SpinelHTTP::Router` maps a verb and a path to a handler, an object with
`call(req, res)`, and runs layers around it.

```ruby
routes = SpinelHTTP::Router.new
routes.use Timing.new
routes.get "/posts/:id", ShowPost.new
routes.namespace "/admin", use: [RequireToken.new] do |admin|
  admin.get "/", Dashboard.new
end
```

## Methods

| | |
|---|---|
| `get`, `post`, `put`, `patch`, `delete(path, handler, use: [])` | Adds a route. A `:name` segment becomes `req.param("name")`. `use:` adds layers for this route only. |
| `use(layer)` | Adds a layer to every route, and to the 404 and 405 answers. |
| `namespace(path, use: []) { \|scope\| }` | Opens a prefix; `scope` takes the same methods. Its layers run for every route inside and for its 404 and 405. |

## Patterns

- A path without parameters is found by a hash lookup, one with
  parameters by a tree.
- A literal segment wins over a parameter at the same position
  (`/posts/new` before `/posts/:id`), and the tree falls back to the
  parameter when the literal branch has no route. Between `/a/:x` and
  `/:y/b`, `/a/b` goes to `/a/:x`: the literal nearer the start wins.
- A parameter matches one non-empty segment. There is no pattern for a
  subtree: `/static` does not match `/static/app.js`, and a trailing
  slash matches only where one was registered.
- A parameter's value has its `%XX` escapes decoded (`+` stays a plus). A
  bad escape is a 400. `%2F` decodes to `/`: check a value before it
  names a file.
- A path with a `.` or `..` segment, written or escaped (`%2e%2e`), is a
  400 before any route sees it.

## Answers

- A `GET` route also answers `HEAD`, with the same headers and no body.
- A path with routes for other verbs answers 405 with `allow`, and
  `OPTIONS` answers 204 with `allow`.
- A path with no route answers 404.

## Layers

A layer is an object with `before(req, res)`, `after(req, res)` or both.

- Befores run in order: the router's, then each enclosing namespace's,
  then the route's own `use:`.
- A before stops the request by raising `SpinelHTTP::Error` or by calling
  `res.halt`. The handler and the later befores are skipped.
- Afters run in reverse order once the response is final, for every
  layer whose before ran, also when the handler raised. `res.status` and
  `res.error` tell how it went.
- An after that raises turns the response into a 500 while it can still
  change; the other afters run all the same.
- `req.context` carries one object from a layer to the handler.

## Refused when declared

`ArgumentError`, at the line that declares it:

- a path not starting with `/`, or a `:` with no name;
- a verb already routed for the path;
- a pattern with the shape of one already routed, under other parameter
  names (`/posts/:id`, then `/posts/:name`);
- a namespace `"/"`, one ending in `/`, or one already open;
- a layer with neither `before` nor `after`;
- any route or layer after the server started.

## Where it differs from Go's ServeMux

| | Here | ServeMux (Go 1.22) |
|---|---|---|
| Parameter | `:id` | `{id}` |
| Rest of the path, subtree | not offered | `{path...}`, a trailing `/` |
| Host in the pattern | no | yes |
| Overlapping patterns of other shapes | the literal nearer the start wins | refused when neither is more specific |
| `.`, `..`, `//` in the path | 400 | 307 to the cleaned path |
| `/x` when only `/x/` exists | 404 | 307 to `/x/` |

## Tested by

`test/router.rb`, `test/router_tree.rb`, `test/router_paths.rb`.
