# The router: verb in the route string, {params}, literal segments before
# params, 404, 405 with Allow, OPTIONS, guards on a prefix with except:,
# and `after` seeing the final status.
require "http/testing"

class Show
  def call(req, res) = res.text("post #{req.param("id")}\n")
end

class New
  def call(req, res) = res.text("new form\n")
end

class Create
  def call(req, res)
    raise HTTP::Error.new(422, "empty body") if req.body.empty?
    res.status = 201
    res.text("created\n")
  end
end

class Login
  def call(req, res) = res.text("login\n")
end

class Admin
  def call(req, res) = res.text("admin #{req.state}\n")
end

class Token
  def check(req, res)
    raise HTTP::Unauthorized unless req.header("authorization") == "Bearer t"
    req.state = "ana"
    nil
  end
end

class Tx
  def check(req, res) = nil

  def after(req, res, error)
    res.header("x-tx", error.nil? && res.status < 400 ? "commit" : "rollback") unless res.sent?
    nil
  end
end

routes = HTTP::Router.new
routes.use "/admin", Token.new, except: ["POST /admin/login"]
routes.handle "GET /posts/{id}", Show.new
routes.handle "GET /posts/new", New.new
routes.handle "POST /posts", Tx.new, Create.new
routes.handle "POST /admin/login", Login.new
routes.handle "GET /admin", Admin.new

def show(r) = puts("#{r.status} #{r.header("allow")} #{r.header("x-tx")} #{r.body.inspect}")

show HTTP::Testing.request(routes, "GET /posts/42")
show HTTP::Testing.request(routes, "GET /posts/new")
show HTTP::Testing.request(routes, "GET /nowhere")
show HTTP::Testing.request(routes, "DELETE /posts/1")
show HTTP::Testing.request(routes, "OPTIONS /posts/1")
show HTTP::Testing.request(routes, "POST /posts", body: "x")
show HTTP::Testing.request(routes, "POST /posts")
show HTTP::Testing.request(routes, "GET /admin")
show HTTP::Testing.request(routes, "GET /admin", headers: { "authorization" => "Bearer t" })
show HTTP::Testing.request(routes, "POST /admin/login")
show HTTP::Testing.request(routes, "HEAD /posts/1")
