module HTTP
  # Reads requests off one socket and writes their responses, until either
  # side closes, the idle timeout passes or the server stops.
  class Connection
    BUFFER_LIMIT = 65536
    VERSIONS = ["HTTP/1.1", "HTTP/1.0"]

    def initialize(sock, server)
      @sock = sock
      @server = server
      @out = +""
      @chunked = false
      @head_only = false
      @keep = false
    end

    def serve
      req = Request.new
      res = Response.new
      loop do
        break if @server.stopping?
        break unless readable_within?(@server.idle_timeout)
        status = read_head(req)
        break if status < 0
        status = read_body(req) if status == 0
        res.reset(self)
        if status > 0
          res.replace(status, HTTP.reason(status).downcase)
          @keep = false
        else
          @keep = req.keep_alive? && !@server.stopping?
          @server.dispatch(req, res)
        end
        @head_only = req.method == "HEAD"
        finish(res)
        @server.finished(req, res)
        break unless @keep
      end
    rescue IOError, SystemCallError
      nil
    ensure
      @sock.close unless @sock.closed?
    end

    # Writes the head with Transfer-Encoding: chunked; the response streams
    # from here on.
    def start_chunked(res)
      @chunked = true
      write_head(res, -1)
      true
    end

    def write_chunk(data)
      return nil if @head_only
      @out.clear
      @out << data.bytesize.to_s(16) << "\r\n" << data << "\r\n"
      @sock.write(@out)
      nil
    end

    private

    def readable_within?(seconds)
      !IO.select([@sock], nil, nil, seconds).nil?
    end

    # 0 when the head is read, an error status when it is not valid, -1 when
    # the peer closed or went quiet.
    def read_head(req)
      deadline = now + @server.header_timeout
      line = read_line(deadline)
      return -1 if line.nil?
      return 400 if line.empty?
      parts = line.split(" ")
      return 400 unless parts.size == 3 && VERSIONS.include?(parts[2])
      req.reset(parts[0], parts[1], parts[2])
      total = line.bytesize
      loop do
        h = read_line(deadline)
        return -1 if h.nil?
        break if h.empty?
        total += h.bytesize
        return 431 if total > @server.max_header_bytes
        colon = h.index(":")
        return 400 if colon.nil? || colon == 0
        req.add_header(h[0, colon].downcase, h[colon + 1, h.size - colon - 1].strip)
      end
      0
    end

    def read_line(deadline)
      left = deadline - now
      return nil if left <= 0 || !readable_within?(left)
      line = @sock.gets
      return nil if line.nil?
      line.chomp
    end

    # 0 when the body is read (or there is none), an error status otherwise.
    def read_body(req)
      te = req.header("transfer-encoding").downcase
      if te == "chunked"
        read_chunked(req)
      elsif !te.empty?
        501
      elsif req.header?("content-length")
        cl = req.header("content-length")
        return 400 unless cl.match?(/\A\d+\z/)
        len = cl.to_i
        return 413 if len > @server.max_body_bytes
        return 0 if len == 0
        data = @sock.read(len)
        return 400 if data.nil? || data.bytesize < len
        req.append_body(data)
        0
      else
        0
      end
    end

    def read_chunked(req)
      size_total = 0
      loop do
        line = @sock.gets
        return 400 if line.nil?
        hex = line.chomp.split(";")[0].to_s.strip
        return 400 unless hex.match?(/\A\h+\z/)
        size = hex.to_i(16)
        if size == 0
          while (t = @sock.gets)
            break if t.chomp.empty?
          end
          return 0
        end
        size_total += size
        return 413 if size_total > @server.max_body_bytes
        data = @sock.read(size)
        return 400 if data.nil? || data.bytesize < size
        req.append_body(data)
        @sock.gets
      end
    end

    def finish(res)
      if @chunked
        res.flush
        @sock.write("0\r\n\r\n") unless @head_only
        @chunked = false
      else
        write_head(res, res.body.bytesize)
        @sock.write(res.body) unless @head_only || res.body.empty?
      end
      nil
    end

    # length -1 means chunked.
    def write_head(res, length)
      @out.clear
      @out << "HTTP/1.1 " << res.status.to_s << " " << HTTP.reason(res.status) << "\r\n"
      res.each_header { |k, v| @out << k << ": " << v << "\r\n" }
      @out << "date: " << @server.date << "\r\n"
      if length < 0
        @out << "transfer-encoding: chunked\r\n"
      else
        @out << "content-length: " << length.to_s << "\r\n"
      end
      @out << (@keep ? "connection: keep-alive\r\n" : "connection: close\r\n")
      @out << "\r\n"
      @sock.write(@out)
      nil
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
