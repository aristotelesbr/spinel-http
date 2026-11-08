# A SpinelHTTP::Error becomes its status; any other exception a 500 with no
# detail in the body; both go through the errors object. After the head
# is on the wire nothing can replace the response: the connection closes.
# Common statuses have their reason phrase.
require "spinel_http/testing"

class App
  def call(req, res)
    raise SpinelHTTP::NotFound, "no post 9" if req.path == "/missing"
    raise SpinelHTTP::Error.new(422, "empty body") if req.path == "/invalid"
    raise ArgumentError, "secret detail" if req.path == "/crash"
    if req.path == "/late"
      res.write("partial")
      res.flush
      raise "after the head"
    end
    res.text("ok\n")
  end
end

class JsonErrors
  def call(status, message, res)
    res.header("content-type", "application/json")
    res.write("{\"status\":")
    res.write_int(status)
    res.write(",\"error\":\"")
    res.write(message)
    res.write("\"}\n")
  end
end

["/missing", "/invalid", "/crash"].each do |path|
  r = SpinelHTTP::Testing.request(App.new, "GET #{path}")
  puts "#{path} #{r.status} #{r.header("content-type")} #{r.body.inspect}"
end
json = SpinelHTTP::Server.new(App.new, errors: JsonErrors.new)
r = SpinelHTTP::Testing.request(App.new, "GET /missing", server: json)
puts "json #{r.status} #{r.header("content-type")} #{r.body.inspect}"
answer = SpinelHTTP::Testing.raw(App.new, "GET /late HTTP/1.1\r\nhost: t\r\n\r\n")
puts "late: #{answer.include?("partial")} no_500=#{!answer.include?(" 500 ")} terminated=#{answer.end_with?("0\r\n\r\n")}"
[302, 429, 505].each { |status| puts SpinelHTTP.status_line(status).inspect }
puts SpinelHTTP::Error.new(429).message
