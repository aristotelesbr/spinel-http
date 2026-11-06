# The router: verb methods, :params, 404, 405 with Allow, OPTIONS, HEAD,
# layers with before/after on the router, on namespaces (nested) and on
# one route, afters seeing the final status and res.error, a before that
# answers with res.halt, an after that raises (the outer afters still
# run), namespaces with :params covering their 404s, and req.context.
require "http/testing"

class Show
  def call(req, res) = res.text("post #{req.param("id")}\n")
end

class Create
  def call(req, res)
    raise HTTP::Error.new(422, "empty body") if req.body.empty?
    res.status = 201
    res.text("created\n")
  end
end

class Boom
  def call(req, res) = raise("boom")
end

class Login
  def call(req, res) = res.text("login\n")
end

class Dashboard
  def call(req, res) = res.text("admin #{req.context.user}\n")
end

class Monthly
  def call(req, res) = res.text("monthly for #{req.context.user}\n")
end

class Session
  attr_reader :user, :role

  def initialize(user, role)
    @user = user
    @role = role
  end
end

# Only after: tags every answer, 404s included.
class Tag
  def after(req, res)
    res.header("x-tag", "1") unless res.sent?
  end
end

class Token
  def before(req, res)
    raise HTTP::Unauthorized unless req.header("authorization") == "Bearer t"
    req.context = Session.new("ana", req.header("x-role"))
  end
end

class Role
  def initialize(role)
    @role = role
  end

  def before(req, res)
    raise HTTP::Error.new(403, "forbidden") unless req.context.role == @role
  end
end

# Both sides: what a transaction would do, and why it failed.
class Tx
  def before(req, res) = nil

  def after(req, res)
    tx = res.status < 400 ? "commit" : "rollback"
    tx = "#{tx} (#{res.error.message})" if res.error
    res.header("x-tx", tx) unless res.sent?
  end
end

# Answers 304 itself when the client has the current version; the handler
# never runs then, and the after still stamps the version.
class Cache
  def before(req, res)
    res.halt(304) if req.header("if-none-match") == "v1"
  end

  def after(req, res)
    res.header("etag", "v1") unless res.sent?
  end
end

class Page
  def call(req, res) = res.text("page built\n")
end

class Explodes
  def after(req, res) = raise("after blew up")
end

class Member
  def before(req, res)
    raise HTTP::Unauthorized unless req.header("authorization") == "Bearer t"
  end
end

# Answers a preflight itself, keeping the status it set (no argument).
class Preflight
  def before(req, res)
    return unless req.header?("access-control-request-method")
    res.status = 204
    res.header("access-control-allow-origin", "*")
    res.halt
  end
end

routes = HTTP::Router.new
routes.use Tag.new
routes.get "/posts/:id", Show.new
routes.post "/posts", Create.new, use: [Tx.new]
routes.post "/boom", Boom.new, use: [Tx.new]
routes.post "/admin/login", Login.new
routes.get "/page", Page.new, use: [Cache.new, Tx.new]
routes.post "/api", Page.new, use: [Preflight.new]
routes.get "/fragile", Page.new, use: [Tx.new, Explodes.new]
routes.namespace "/orgs/:org", use: [Member.new] do |org|
  org.get "/teams/:team", Page.new
end
routes.namespace "/admin", use: [Token.new] do |admin|
  admin.get "/", Dashboard.new
  admin.namespace "/reports", use: [Role.new("finance")] do |reports|
    reports.get "/monthly", Monthly.new
  end
end

def show(r) = puts("#{r.status} tag=#{r.header("x-tag")} allow=#{r.header("allow")} tx=#{r.header("x-tx")} etag=#{r.header("etag")} #{r.body.inspect}")

show HTTP::Testing.request(routes, "GET /posts/42")
show HTTP::Testing.request(routes, "GET /nowhere")
show HTTP::Testing.request(routes, "DELETE /posts/1")
show HTTP::Testing.request(routes, "OPTIONS /posts/1")
show HTTP::Testing.request(routes, "HEAD /posts/1")
show HTTP::Testing.request(routes, "POST /posts", body: "x")
show HTTP::Testing.request(routes, "POST /posts")
show HTTP::Testing.request(routes, "POST /boom")
show HTTP::Testing.request(routes, "POST /admin/login")
show HTTP::Testing.request(routes, "GET /page")
show HTTP::Testing.request(routes, "GET /page", headers: { "if-none-match" => "v1" })
show HTTP::Testing.request(routes, "POST /api", headers: { "access-control-request-method" => "POST" })
show HTTP::Testing.request(routes, "POST /api")
show HTTP::Testing.request(routes, "GET /fragile")
show HTTP::Testing.request(routes, "GET /orgs/1/teams/2")
show HTTP::Testing.request(routes, "GET /orgs/1/nope")
show HTTP::Testing.request(routes, "GET /orgs/1/nope", headers: { "authorization" => "Bearer t" })
show HTTP::Testing.request(routes, "GET /admin")
show HTTP::Testing.request(routes, "GET /admin", headers: { "authorization" => "Bearer t" })
show HTTP::Testing.request(routes, "GET /admin/nothing")
show HTTP::Testing.request(routes, "GET /admin/reports/monthly", headers: { "authorization" => "Bearer t" })
show HTTP::Testing.request(routes, "GET /admin/reports/monthly", headers: { "authorization" => "Bearer t", "x-role" => "finance" })

# Mistakes are caught when routes are declared.
class Nothing
end

def refused
  yield
  puts "accepted"
rescue ArgumentError => e
  puts "refused: #{e.message}"
end

more = HTTP::Router.new
refused { more.use Nothing.new }
refused { more.get "posts", Show.new }
refused { more.get "/a/:", Show.new }
more.get "/a", Show.new
refused { more.get "/a", Show.new }
refused { more.namespace("/") { |s| s.get "/x", Show.new } }
refused { more.namespace("/b/") { |s| s.get "/x", Show.new } }
more.namespace("/c") { |s| s.get "/x", Show.new }
refused { more.namespace("/c") { |s| s.get "/y", Show.new } }
more.prepare
refused { more.get "/b", Show.new }
