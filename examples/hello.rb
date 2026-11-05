require_relative "../http/server"

class Hello
  def call(req, res)
    res.text("Hello world, got #{req.path}!\n")
  end
end

server = HTTP::Server.new(Hello.new, port: ENV.fetch("PORT", "8080").to_i)
server.listen { |port| puts "listening on 127.0.0.1:#{port}"; $stdout.flush }
