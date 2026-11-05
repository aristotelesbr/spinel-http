# Without flush the response goes out whole with Content-Length; flush
# sends the head and streams the rest as chunks. text sets a text/plain
# content type unless one was set; write_int writes digits.
require "http/testing"

class Whole
  def call(req, res)
    res.status = 201
    res.header("x-id", "7")
    res.text("id ")
    res.write_int(7)
    res.write_int(-42)
    res.text("\n")
  end
end

class Streamed
  def call(req, res)
    res.header("content-type", "text/event-stream")
    res.write("data: 1\n\n")
    res.flush
    puts "sent? #{res.sent?}"
    res.write("data: 2\n\n")
  end
end

r = HTTP::Testing.request(Whole.new, "GET /")
puts r.status, r.header("x-id"), r.header("content-type"), r.header("content-length"), r.body.inspect
r = HTTP::Testing.request(Streamed.new, "GET /")
puts r.header("transfer-encoding"), r.header("content-type"), r.body.inspect
r = HTTP::Testing.request(Whole.new, "HEAD /")
puts r.status, r.header("content-length"), r.body.inspect
