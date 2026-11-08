# One connection carries several requests (HTTP/1.1 keeps it open by
# default, HTTP/1.0 only when asked); nothing of one request leaks into
# the next; "connection: close" ends it.
require "spinel_http/testing"

class Echo
  def call(req, res)
    res.header("x-seen", req.header("x-tag")) unless req.header("x-tag").empty?
    res.text("#{req.method} #{req.path}\n")
  end
end

data = "GET /a HTTP/1.1\r\nhost: t\r\nx-tag: first\r\n\r\n" \
       "POST /b HTTP/1.1\r\nhost: t\r\ncontent-length: 3\r\n\r\nxyz" \
       "GET /c HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"
answer = SpinelHTTP::Testing.raw(Echo.new, data)
answer.split("HTTP/1.1 ").drop(1).each do |part|
  head, body = part.split("\r\n\r\n", 2)
  lines = head.split("\r\n").reject { |l| l.start_with?("date:") }
  puts lines.join(" | ") + " || " + body.inspect
end
answer = SpinelHTTP::Testing.raw(Echo.new, "GET /old HTTP/1.0\r\n\r\n")
puts answer.include?("connection: close")
