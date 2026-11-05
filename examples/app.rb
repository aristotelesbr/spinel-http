# Example app for the v0.1 feature set; probes/probe.rb drives it.
require_relative "../http/server"

POSTS = { "1" => "Hello, Spinel", "2" => "Second post" }

class Session
  attr_reader :user
  def initialize(user)
    @user = user
  end
end

class Home
  def call(req, res) = res.text("home\n")
end

class NewPost
  def call(req, res) = res.text("form\n")
end

class ShowPost
  def call(req, res)
    title = POSTS.fetch(req.param("id")) { raise HTTP::NotFound, "no post #{req.param("id")}" }
    res.text("#{title}\n")
  end
end

class CreatePost
  def call(req, res)
    raise HTTP::Error.new(422, "empty body") if req.body.empty?
    res.status = 201
    res.text("created #{req.body.bytesize} bytes\n")
  end
end

class Big
  def call(req, res)
    line = "x" * 1023 + "\n"
    200.times { res.write(line) }
    nil
  end
end

class Boom
  def call(req, res) = raise("boom")
end

class Slow
  def call(req, res)
    sleep 0.3
    res.text("slept\n")
  end
end

class Counter
  def initialize
    @lock = Mutex.new
    @n = 0
  end

  def call(req, res)
    n = @lock.synchronize { @n += 1 }
    res.text("#{n}\n")
  end
end

class Login
  def call(req, res) = res.text("token: secret\n")
end

class Dashboard
  def call(req, res) = res.text("hello #{req.state.user}\n")
end

class RequireToken
  def check(req, res)
    raise HTTP::Unauthorized unless req.header("authorization") == "Bearer secret"
    req.state = Session.new("admin")
    nil
  end
end

# Marks the response with what a transaction would do.
class Transaction
  def check(req, res) = nil

  def after(req, res, error)
    res.header("x-tx", error.nil? && res.status < 400 ? "commit" : "rollback") unless res.sent?
    nil
  end
end

routes = HTTP::Router.new
routes.use "/admin", RequireToken.new, except: ["POST /admin/login"]

routes.handle "GET /",              Home.new
routes.handle "GET /posts/new",     NewPost.new
routes.handle "GET /posts/{id}",    ShowPost.new
routes.handle "POST /posts",        Transaction.new, CreatePost.new
routes.handle "GET /big",           Big.new
routes.handle "GET /boom",          Boom.new
routes.handle "GET /slow",          Slow.new
routes.handle "GET /count",         Counter.new
routes.handle "POST /admin/login",  Login.new
routes.handle "GET /admin",         Dashboard.new

server = HTTP::Server.new(routes,
  port: ENV.fetch("PORT", "8080").to_i,
  observer: HTTP::AccessLog.new($stderr),
  idle_timeout: ENV.fetch("IDLE", "5").to_f,
  max_header_bytes: 4096,
  max_body_bytes: 65536)
server.listen { |port| puts "listening on 127.0.0.1:#{port}"; $stdout.flush }
puts "stopped"
