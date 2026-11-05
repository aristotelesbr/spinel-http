# Drives examples/app.rb on PORT and prints a deterministic transcript (dates
# masked). Run on CRuby against the CRuby-hosted app and the Spinel binary,
# then diff: probes/compare.sh.
require "socket"

PORT = ENV.fetch("PORT", "8080").to_i

def read_response(sock)
  status = sock.gets
  return "(closed)" if status.nil?
  lines = [status.chomp]
  len = 0
  chunked = false
  while (h = sock.gets)
    h = h.chomp
    break if h.empty?
    name, value = h.split(": ", 2)
    name = name.downcase
    value = "<date>" if name == "date"
    len = value.to_i if name == "content-length"
    chunked = true if name == "transfer-encoding" && value == "chunked"
    lines << "#{name}: #{value}"
  end
  if chunked
    total = 0
    chunks = 0
    loop do
      size = sock.gets.to_s.chomp.to_i(16)
      if size == 0
        sock.gets
        break
      end
      total += sock.read(size).bytesize
      sock.read(2)
      chunks += 1
    end
    lines << "body=<#{total} bytes in chunks>"
  elsif $head
    lines << "body=(none)"
  else
    body = sock.read(len)
    lines << "body=#{body.size > 120 ? "<#{body.bytesize} bytes>" : body.inspect}"
  end
  lines.join("\n")
end

def exchange(raw, head: false)
  sock = TCPSocket.new("127.0.0.1", PORT)
  sock.write(raw)
  $head = head
  out = read_response(sock)
  $head = false
  sock.close
  out
end

def get(path, extra = "")
  exchange("GET #{path} HTTP/1.1\r\nHost: x\r\n#{extra}Connection: close\r\n\r\n")
end

def section(title)
  puts "== #{title}"
end

section "GET /";                          puts get("/")
section "literal beats param";            puts get("/posts/new")
section "param";                          puts get("/posts/2")
section "param, missing post";            puts get("/posts/9")
section "unknown path";                   puts get("/nope")
section "query string";                   puts get("/posts/1?x=1")
section "HEAD"; puts exchange("HEAD / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", head: true)
section "OPTIONS"; puts exchange("OPTIONS /posts HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
section "405 with Allow"; puts exchange("DELETE /posts HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")

section "POST Content-Length (guard after: commit)"
puts exchange("POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
section "POST chunked"
puts exchange("POST /posts HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\nabcd\r\n3;ext=1\r\nefg\r\n0\r\n\r\n")
section "POST empty (guard after: rollback)"
puts exchange("POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

section "area without token";             puts get("/admin")
section "area with token";                puts get("/admin", "Authorization: Bearer secret\r\n")
section "except: login without token"
puts exchange("POST /admin/login HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
section "area answers 401 before 404";    puts get("/admin/nope")
section "404 inside the area with token"; puts get("/admin/nope", "Authorization: Bearer secret\r\n")

section "large response streams chunked"; puts get("/big")
section "exception: 500, then the connection still serves"
sock = TCPSocket.new("127.0.0.1", PORT)
sock.write("GET /boom HTTP/1.1\r\nHost: x\r\n\r\n")
puts read_response(sock)
sock.write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
puts read_response(sock)
sock.close

section "malformed request line";         puts exchange("HELLO\r\n\r\n")
section "HTTP/1.0 closes";                puts exchange("GET / HTTP/1.0\r\n\r\n")
section "header too large"
puts exchange("GET / HTTP/1.1\r\nHost: x\r\nX-Big: #{"a" * 5000}\r\n\r\n")
section "body too large"
puts exchange("POST /posts HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n")
section "unsupported transfer coding"
puts exchange("POST /posts HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n")

section "keep-alive: three requests on one connection"
sock = TCPSocket.new("127.0.0.1", PORT)
["/", "/posts/1", "/posts/2"].each_with_index do |path, i|
  close = i == 2 ? "Connection: close\r\n" : ""
  sock.write("GET #{path} HTTP/1.1\r\nHost: x\r\n#{close}\r\n")
  puts read_response(sock)
end
sock.close

section "idle connection closes after the idle timeout"
sock = TCPSocket.new("127.0.0.1", PORT)
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
closed = IO.select([sock], nil, nil, 3) && sock.read(1).nil?
waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "closed=#{closed ? "yes" : "no"} within_window=#{waited > 0.8 && waited < 2.5 ? "yes" : "no (#{waited.round(2)} s)"}"
sock.close

section "8 parallel /slow (0.3 s each)"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
8.times.map { Thread.new { get("/slow") } }.each(&:join)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
puts "parallel=#{elapsed < 0.6 ? "yes" : "no (#{elapsed.round(2)} s)"}"

section "600 /count at concurrency 32"
queue = Queue.new
600.times { queue << 1 }
32.times { queue << nil }
bodies = Queue.new
32.times.map do
  Thread.new do
    while queue.pop
      bodies << get("/count")[/body="(\d+)/, 1].to_i
    end
  end
end.each(&:join)
seen = []
seen << bodies.pop until bodies.empty?
puts "requests=#{seen.size} max=#{seen.max} distinct=#{seen.uniq.size}"
