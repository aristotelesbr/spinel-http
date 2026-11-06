module HTTP
  # The answer being built: status, headers and a body buffer, reused for
  # every request of the connection. Without #flush the server sends it
  # whole, with Content-Length. #flush (or a buffer past 64 KB) sends the
  # head and what is buffered, and from then on every write streams.
  class Response
    LIMIT = 65536

    attr_reader :status, :body, :bytes_written

    # The exception that became this response, nil when none did.
    attr_accessor :error

    def initialize(wire, server, errors)
      @wire = wire
      @server = server
      @errors = errors
      @body = String.new(capacity: LIMIT)
      @headers = [""]
      @headers.clear
      @status = 200
      @bytes_written = 0
      @sent = false
      @streaming = false
      @taken = false
      @halted = false
      @error = nil
    end

    def reset
      @status = 200
      @headers.clear
      @body.replace("")
      @bytes_written = 0
      @sent = false
      @streaming = false
      @taken = false
      @halted = false
      @error = nil
      nil
    end

    def status=(code)
      raise IOError, "status already sent" if @sent
      @status = code
    end

    # Adds a header; names go out as given (lowercase is the convention).
    def header(name, value)
      raise IOError, "headers already sent" if @sent
      @headers << name << value
      nil
    end

    # The value of a header set so far, "" when absent.
    def header_value(name)
      i = 0
      while i < @headers.size
        return @headers[i + 1] if @headers[i] == name
        i += 2
      end
      ""
    end

    def header?(name)
      i = 0
      while i < @headers.size
        return true if @headers[i] == name
        i += 2
      end
      false
    end

    def write(data)
      @bytes_written += data.bytesize
      if @streaming
        @wire.write_chunk(data) unless @wire.head_only?
      else
        @body << data
        flush if @body.bytesize >= LIMIT
      end
      nil
    end

    # Writes the digits of an Integer, without building a String for it.
    def write_int(n)
      if n < 0
        write("-")
        n = -n
      end
      from = @body.bytesize
      d = 1
      t = n
      while t >= 10
        t /= 10
        d += 1
      end
      d.times { @body << "0" }
      k = from + d - 1
      d.times do
        @body.setbyte(k, 48 + n % 10)
        n /= 10
        k -= 1
      end
      @bytes_written += d
      flush if @streaming || @body.bytesize >= LIMIT
      nil
    end

    # Writes text, setting a text/plain content type if none was set.
    def text(s)
      header("content-type", "text/plain; charset=utf-8") unless @sent || header?("content-type")
      write(s)
    end

    # Sends the head (once) and what is buffered; the rest streams.
    def flush
      unless @sent
        @sent = true
        @streaming = true
        @wire.write_head(@status, @headers, -1, @server.date)
      end
      @wire.write_chunk(@body) unless @wire.head_only?
      @body.replace("")
      nil
    end

    def sent? = @sent
    def taken? = @taken

    # Answers now with what was written so far, under status (by default
    # the one already set): the befores after this one and the handler are
    # skipped (the afters still run).
    def halt(status = @status)
      self.status = status.to_i # (to_i: typed even when no app calls halt)
      @halted = true
      nil
    end

    def halted? = @halted

    # Sends the head as it stands (status 101, say) and hands over the
    # socket: the server no longer reads or writes this connection.
    def take
      raise IOError, "head already sent" if @sent
      @sent = true
      @taken = true
      @wire.write_head(@status, @headers, -2, @server.date)
      @wire.sock
    end

    # Replaces the response with an error answer, through the server's
    # errors object. A head on the wire cannot be replaced: IOError.
    def fail(status, message)
      raise IOError, "response already started" if @sent
      allow = +""
      allow << header_value("allow")
      @headers.clear
      @body.replace("")
      @bytes_written = 0
      @status = status
      header("allow", allow) unless allow.empty?
      @errors.call(status, message, self)
      nil
    end

    # Called by the server after the app returns.
    def finish
      if @streaming
        @wire.write_chunk(@body) unless @wire.head_only?
        @wire.end_chunks unless @wire.head_only?
      else
        @wire.write_head(@status, @headers, @body.bytesize, @server.date)
        @wire.write(@body) unless @wire.head_only?
      end
      nil
    end
  end

  # The default errors object: the message as plain text.
  class PlainErrors
    def call(status, message, res)
      res.text(message)
      res.text("\n")
    end
  end
end
