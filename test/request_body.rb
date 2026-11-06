# The body arrives on demand: req.body reads it whole on first use,
# req.each_chunk in pieces; chunked request bodies are decoded; a body
# past max_body_bytes is refused with 413 before the app runs.
require "http/testing"

class Count
  def call(req, res)
    if req.path == "/whole"
      res.text("#{req.body.bytesize} #{req.body}\n")
    elsif req.path == "/size"
      res.text("#{req.body.bytesize} bytes read whole\n")
    else
      n = 0
      pieces = 0
      req.each_chunk do |piece|
        n += piece.bytesize
        pieces += 1
      end
      res.text("#{n} bytes\n")
    end
  end
end

r = HTTP::Testing.request(Count.new, "POST /whole", body: "hello")
puts r.body
r = HTTP::Testing.request(Count.new, "POST /pieces", body: "x" * 200_000)
puts r.body
chunked = "POST /whole HTTP/1.1\r\nhost: t\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n" \
          "5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\nx-trailer: 1\r\n\r\n"
puts HTTP::Testing.raw(Count.new, chunked).split("\r\n\r\n", 2)[1]
small = HTTP::Server.new(Count.new, max_body_bytes: 10)
r = HTTP::Testing.request(Count.new, "POST /whole", body: "x" * 11, server: small)
puts r.status

# A big body read whole, then a small one on the same connection: the
# second request reads only its own.
big = "POST /size HTTP/1.1\r\nhost: t\r\ncontent-length: 200000\r\n\r\n" + ("z" * 200_000) +
      "POST /whole HTTP/1.1\r\nhost: t\r\ncontent-length: 2\r\nconnection: close\r\n\r\nhi"
HTTP::Testing.raw(Count.new, big).gsub("\r\n", "\n").split("\n").each { |l| puts l if l.start_with?("200000", "2 hi", "zzz") }
