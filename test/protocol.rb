# What the server owns and what the app may not override: header names and
# values are checked (no CR/LF from the app), content-length and
# transfer-encoding are the server's, "connection: close" closes once, an
# app date replaces the server's; 204 and 304 go out with no length and no
# body; "Expect: 100-continue" is answered when the body is first read (and
# not at all when it is not, which closes), any other expectation is a 417;
# a body left unread is drained up to 256 KB, past that the connection
# closes.
require "http/testing"

class SetHeader
  def initialize(name, value)
    @name = name
    @value = value
  end

  def call(req, res)
    res.header(@name, @value)
    res.text("ok\n")
  end
end

class Empty
  def initialize(status)
    @status = status
  end

  def call(req, res)
    res.status = @status
    res.header("etag", "v1")
    res.text("this body must not go out\n")
  end
end

class ReadBody
  def call(req, res) = res.text("read #{req.body.bytesize}\n")
end

class Ignore
  def call(req, res) = res.text("ignored\n")
end

# Status line, the framing headers and body of every answer in `answer`.
def answers(answer)
  out = []
  rest = answer
  until rest.empty?
    head, rest = rest.split("\r\n\r\n", 2)
    rest ||= ""
    lines = head.split("\r\n")
    picked = lines.drop(1).select { |l| l.start_with?("content-length", "transfer-encoding", "connection", "date: Sat") }
    picked << "dates=#{lines.count { |l| l.start_with?("date:") }}"
    len = (lines.find { |l| l.start_with?("content-length: ") } || "content-length: 0").split(": ")[1].to_i
    body = rest[0, len]
    rest = rest[len, rest.size - len] || ""
    out << "#{lines[0]} | #{picked.join(" | ")} | #{body.inspect}"
  end
  out
end

def show(app, data) = answers(HTTP::Testing.raw(app, data)).each { |a| puts "  #{a}" }

GET = "GET / HTTP/1.1\r\nhost: t\r\n\r\n"
LAST = "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"

puts "app headers"
[["x-ok", "fine"], ["bad name", "x"], ["x-split", "a\r\nset-cookie: evil=1"], ["content-length", "5"],
 ["Transfer-Encoding", "chunked"], ["Connection", "close"], ["date", "Sat, 01 Jan 2000 00:00:00 GMT"]].each do |name, value|
  puts "#{name.inspect}:"
  show(SetHeader.new(name, value), name == "Connection" ? GET + LAST : LAST)
end

puts "no body"
[204, 304].each do |status|
  puts "#{status}, then a second request on the connection:"
  show(Empty.new(status), GET + "GET / HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n")
end

puts "expect"
body = "POST / HTTP/1.1\r\nhost: t\r\ncontent-length: 5\r\nexpect: 100-continue\r\n\r\nhello"
puts "100-continue, body read:"
show(ReadBody.new, body + LAST)
puts "100-continue, body not read:"
show(Ignore.new, body + LAST)
puts "other expectation:"
show(Ignore.new, "POST / HTTP/1.1\r\nhost: t\r\ncontent-length: 5\r\nexpect: magic\r\n\r\nhello")

puts "unread body"
[100_000, 300_000].each do |n|
  puts "#{n} bytes unread, then a second request:"
  show(Ignore.new, "POST / HTTP/1.1\r\nhost: t\r\ncontent-length: #{n}\r\n\r\n" + ("x" * n) + LAST)
end
