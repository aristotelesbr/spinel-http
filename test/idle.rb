# While listening, the watchdog closes a connection that waits for its next
# request past idle_timeout (no timer per connection), and a shutdown
# closes the connections waiting that way at once instead of letting them
# run out their idle time.
require "http/server"
require "socket"

class Ok
  def call(req, res) = res.text("ok\n")
end

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# Seconds until the server closes s (nil if not within limit).
def closed_after(s, limit)
  t = now
  while now - t < limit
    next unless IO.select([s], nil, nil, 0.1)
    return now - t if s.read_nonblock(4096, exception: false).nil?
  end
  nil
end

server = HTTP::Server.new(Ok.new, port: 0, idle_timeout: 1.0, header_timeout: 10.0)
port = nil
thread = Thread.new { server.listen { |p| port = p } }
sleep 0.01 until port

served = TCPSocket.new("127.0.0.1", port)
served.write("GET / HTTP/1.1\r\nhost: t\r\n\r\n")
answer = +""
answer << served.readpartial(4096) until answer.include?("ok\n")
idle = closed_after(served, 4.0)
puts "answered: #{answer.start_with?("HTTP/1.1 200")}"
puts "idle connection closed between 1 and 2.5 s: #{!idle.nil? && idle >= 0.9 && idle <= 2.5}"

waiting = TCPSocket.new("127.0.0.1", port)
waiting.write("GET / HTTP/1.1\r\nhost: t\r\n\r\n")
answer = +""
answer << waiting.readpartial(4096) until answer.include?("ok\n")
t = now
server.shutdown
closed = closed_after(waiting, 3.0)
thread.join
puts "waiting connection closed by the shutdown within 1 s: #{!closed.nil? && closed < 1.0}"
puts "listen returned within 2 s: #{now - t < 2.0}"
