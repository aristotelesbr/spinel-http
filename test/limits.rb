# The core answers malformed or ambiguous requests itself and closes:
# head too large (431), body too large or a number too long (413), any
# doubt about where the body ends or a bad token (400), an unknown method
# or transfer coding (501), an unknown version (505).
require "spinel_http/testing"

class Ok
  def call(req, res) = res.text("ok\n")
end

def status_of(data, server = nil)
  answer = SpinelHTTP::Testing.raw(Ok.new, data, server: server)
  line = answer.split("\r\n", 2)[0].to_s
  closes = answer.include?("connection: close")
  "#{line.split(" ")[1] || "none"}#{closes ? " close" : ""}"
end

H = "host: t\r\n"
cases = {
  "valid" => "GET / HTTP/1.1\r\n#{H}connection: close\r\n\r\n",
  "two content-length" => "POST / HTTP/1.1\r\n#{H}content-length: 1\r\ncontent-length: 2\r\n\r\nab",
  "length and chunked" => "POST / HTTP/1.1\r\n#{H}content-length: 1\r\ntransfer-encoding: chunked\r\n\r\n",
  "space before colon" => "GET / HTTP/1.1\r\n#{H}x-a : 1\r\n\r\n",
  "control byte" => "GET / HTTP/1.1\r\n#{H}x-a: a\u0001b\r\n\r\n",
  "bare LF" => "GET / HTTP/1.1\n#{H}\r\n",
  "folded line" => "GET / HTTP/1.1\r\n#{H}x-a: 1\r\n  2\r\n\r\n",
  "no host" => "GET / HTTP/1.1\r\n\r\n",
  "two hosts" => "GET / HTTP/1.1\r\n#{H}#{H}\r\n",
  "lowercase method" => "get / HTTP/1.1\r\n#{H}\r\n",
  "unknown method" => "BREW / HTTP/1.1\r\n#{H}\r\n",
  "gzip coding" => "POST / HTTP/1.1\r\n#{H}transfer-encoding: gzip\r\n\r\n",
  "version 2.0" => "GET / HTTP/2.0\r\n#{H}\r\n",
  "plus length" => "POST / HTTP/1.1\r\n#{H}content-length: +5\r\n\r\n",
  "13-digit length" => "POST / HTTP/1.1\r\n#{H}content-length: 1234567890123\r\n\r\n",
  "huge chunk size" => "POST / HTTP/1.1\r\n#{H}transfer-encoding: chunked\r\nconnection: close\r\n\r\nfffffffffffffffff\r\n",
  "head too large" => "GET / HTTP/1.1\r\n#{H}x-big: #{"a" * 17000}\r\n\r\n",
}
cases.each { |name, data| puts "#{name}: #{status_of(data)}" }
