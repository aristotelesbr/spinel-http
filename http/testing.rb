require_relative "server"

module HTTP
  # Calls an app the way a client would and returns what came back:
  #
  #   res = HTTP::Testing.request(app, "GET /posts/1", headers: { "accept" => "text/plain" })
  #   res.status  # => 200
  #   res.body    # => "Hello, Spinel\n"
  #
  # Goes through a loopback socket and the real server, so the request
  # meets the same parser and limits as in production.
  module Testing
    class Result
      attr_reader :status, :headers, :body

      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end

      def header(name) = @headers.fetch(name, "")
    end

    def self.request(app, line, headers: {}, body: "", server: nil)
      space = line.index(" ")
      raise ArgumentError, "request needs a verb: #{line.inspect}" if space.nil?
      app.prepare if app.respond_to?(:prepare)
      server ||= Server.new(app)
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]
      thread = Thread.new(listener) { |l| server.serve(l.accept) }
      client = TCPSocket.new("127.0.0.1", port)
      raw = +"#{line} HTTP/1.1\r\nhost: test\r\nconnection: close\r\n"
      headers.each { |k, v| raw << k << ": " << v << "\r\n" }
      raw << "content-length: " << body.bytesize.to_s << "\r\n" unless body.empty?
      raw << "\r\n" << body
      client.write(raw)
      answer = client.read
      client.close
      thread.join
      listener.close
      parse(answer, line.start_with?("HEAD "))
    end

    def self.parse(answer, head)
      stop = answer.index("\r\n\r\n") || answer.size
      lines = answer[0, stop].split("\r\n")
      status = lines[0].to_s.split(" ")[1].to_i
      headers = {}
      lines.drop(1).each do |l|
        c = l.index(":")
        headers[l[0, c].downcase] = l[c + 1, l.size - c - 1].strip if c
      end
      rest = answer[stop + 4, answer.size - stop - 4] || ""
      body = headers["transfer-encoding"] == "chunked" && !head ? dechunk(rest) : rest
      Result.new(status, headers, body)
    end

    def self.dechunk(s)
      out = +""
      pos = 0
      loop do
        nl = s.index("\r\n", pos)
        break if nl.nil?
        size = s[pos, nl - pos].to_i(16)
        break if size == 0
        out << s[nl + 2, size]
        pos = nl + 2 + size + 2
      end
      out
    end
  end
end
