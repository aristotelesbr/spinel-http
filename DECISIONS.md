# Decisions

What the package chose, what it turned down, and what it leaves out, so
none of it has to be argued twice. Status is **adopted**, **refused** or
**out of scope**.

## Shape of the code

**Objects with `call`, `before` and `after`: adopted.** Spinel compiles
the whole program ahead of time and works out the type of every value.
With one class per handler and a typed request, each call is a direct
call. A Hash of mixed values (a Rack `env`), or blocks stored and called
later, leave values whose type is known only at run time, and those go
through a box. A block DSL (`get "/" do ... end`) is **refused** for the
same reason; it can live in another package on top of this one.

**A routing tree of nested blocks (`r.on`, `r.get`): refused.** Same
reason.

**One thread per connection, blocking-style code: adopted.** In Spinel
the threads are green: one waiting on the network holds no system
thread. The cost is a `Mutex` around state shared between requests.

**The same code on CRuby: adopted.** The package is plain Ruby with no C.
Each test's expected output is what CRuby prints, and the binary has to
print the same.

**A few lines that tell the compiler a type: adopted.** A `to_s` on a path
argument, or a collection made with one element and then cleared, give
Spinel a type it could not see otherwise.

## Protocol

**The server owns the framing: adopted.** The app cannot set
`content-length` or `transfer-encoding`, and a header value cannot hold
CR or LF. A length that disagreed with the body would let a proxy and
the server split the stream at different places (request smuggling).

**A strict parser: adopted.** A request a proxy could read two ways is a
400 and a close.

**Limits on by default: adopted.** Head and body sizes, a head deadline,
a minimum body rate, an idle deadline and a write deadline. A server
without them can be held by one slow client.

**A watchdog instead of a timer per connection: adopted.** One thread
checks the open connections every half second.

**Reuse per connection: adopted.** Buffers, request and response are
reused for every request a connection carries; a header or field becomes
a String only when asked for.

## Routing

**Literal before parameter, per segment: adopted.** The tree is walked
left to right, and the first literal that has a route wins. Go 1.22
instead picks the most specific pattern and refuses the pairs where
neither is.

**A parameter named the same at one position: adopted.** Two names for
one position would share a node of the tree, and the later route would
replace the earlier in silence.

**Decoded parameters: adopted.** As the query is decoded, and as Rails,
Sinatra and Go hand them.

**A 400 for `.` and `..` segments: adopted.** Go answers a 307 to the
cleaned path. A 400 is simpler, and no handler sees a `..`.

**Redirects for a missing trailing slash: refused.** A path matches only
what was registered.

**Subtree and rest-of-path patterns (`/static/`, `{path...}`): out of
scope for now.**

## Left out

**TLS and HTTP/2: out of scope.** Put a proxy in front (nginx, Caddy, a
load balancer); it speaks HTTP/1.1 to the server.

**WebSocket: out of scope.** `res.take` hands over the socket after a 101,
for a package that does it.
