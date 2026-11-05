# The request is a view over the connection's buffer: method, path and
# query come from the request line; header names match without regard to
# case; a header that was not sent reads as "".
require "http/testing"

class Show
  def call(req, res)
    res.text("#{req.method} #{req.path} q=#{req.query} target=#{req.target} #{req.version}\n")
    res.text("accept=#{req.header("ACCEPT")} missing=#{req.header("x-none").inspect}\n")
    res.text("has_accept=#{req.header?("accept")} length=#{req.content_length}\n")
    names = []
    req.each_header { |k, v| names << k }
    res.text("names=#{names.join(",")}\n")
  end
end

r = HTTP::Testing.request(Show.new, "GET /posts/1?x=1&y=2", headers: { "Accept" => "text/plain" })
puts r.status
puts r.body
r = HTTP::Testing.request(Show.new, "POST /up", body: "hello")
puts r.body
