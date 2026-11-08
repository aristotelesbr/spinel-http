# Example app for the v0.1 feature set; probes/probe.rb drives it.
require_relative "../spinel_http/server"

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
    title = POSTS.fetch(req.param("id")) { raise SpinelHTTP::NotFound, "no post #{req.param("id")}" }
    res.text("#{title}\n")
  end
end

class CreatePost
  def call(req, res)
    raise SpinelHTTP::Error.new(422, "empty body") if req.body.empty?
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
  def call(req, res) = res.text("hello #{req.context.user}\n")
end

class RequireToken
  def before(req, res)
    raise SpinelHTTP::Unauthorized unless req.header("authorization") == "Bearer secret"
    req.context = Session.new("admin")
    nil
  end
end

# Marks the response with what a transaction would do.
class Transaction
  def after(req, res)
    res.header("x-tx", res.status < 400 ? "commit" : "rollback") unless res.sent?
    nil
  end
end

routes = SpinelHTTP::Router.new
routes.get "/", Home.new
routes.get "/posts/new", NewPost.new
routes.get "/posts/:id", ShowPost.new
routes.post "/posts", CreatePost.new, use: [Transaction.new]
routes.get "/big", Big.new
routes.get "/boom", Boom.new
routes.get "/slow", Slow.new
routes.get "/count", Counter.new
routes.post "/admin/login", Login.new
routes.namespace "/admin", use: [RequireToken.new] do |admin|
  admin.get "/", Dashboard.new
end

server = SpinelHTTP::Server.new(routes,
  port: ENV.fetch("PORT", "8080").to_i,
  observer: SpinelHTTP::AccessLog.new($stderr),
  idle_timeout: ENV.fetch("IDLE", "5").to_f,
  max_header_bytes: 4096,
  max_body_bytes: 65536)
server.listen { |port| puts "listening on 127.0.0.1:#{port}"; $stdout.flush }
puts "stopped"
