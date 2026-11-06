module HTTP
  # Whether s is the lowercase name `lower`, compared without regard to case.
  def self.named?(s, lower)
    return false unless s.bytesize == lower.bytesize
    i = 0
    while i < s.bytesize
      c = s.getbyte(i)
      c += 32 if c >= 65 && c <= 90
      return false unless c == lower.getbyte(i)
      i += 1
    end
    true
  end

  # A header name: one or more token characters (RFC 9110 5.6.2).
  def self.token?(s)
    return false if s.empty?
    i = 0
    while i < s.bytesize
      c = s.getbyte(i)
      ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ||
           c == 33 || (c >= 35 && c <= 39) || c == 42 || c == 43 || c == 45 || c == 46 ||
           c == 94 || c == 95 || c == 96 || c == 124 || c == 126
      return false unless ok
      i += 1
    end
    true
  end

  # A header value: no control bytes but tab (so no CR or LF to end the
  # line early and start a header of the client's choosing).
  def self.field_value?(s)
    i = 0
    while i < s.bytesize
      c = s.getbyte(i)
      return false if (c < 32 && c != 9) || c == 127
      i += 1
    end
    true
  end

  # The answer being built: status, headers and a body buffer, reused for
  # every request of the connection. Without #flush the server sends it
  # whole, with Content-Length. #flush (or a buffer past 64 KB) sends the
  # head and what is buffered, and from then on every write streams.
  #
  # The server owns how the body is framed and the connection: the app
  # cannot set content-length or transfer-encoding, "connection: close"
  # asks the server to close after this answer.
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
      @own_date = false
      @own_connection = false
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
      @own_date = false
      @own_connection = false
      nil
    end

    def status=(code)
      raise IOError, "status already sent" if @sent
      @status = code
    end

    # Adds a header; names go out as given (lowercase is the convention).
    # ArgumentError for a name that is not a token, a value with a control
    # byte (CR, LF...), or a header that frames the body. A date replaces
    # the server's.
    def header(name, value)
      raise IOError, "headers already sent" if @sent
      if HTTP.named?(name, "content-length") || HTTP.named?(name, "transfer-encoding")
        raise ArgumentError, "#{name} is set by the server"
      end
      raise ArgumentError, "bad header name #{name.inspect}" unless HTTP.token?(name)
      raise ArgumentError, "bad byte in the value of #{name}" unless HTTP.field_value?(value)
      if HTTP.named?(name, "connection")
        if HTTP.named?(value, "close")
          @wire.no_reuse
          return nil
        end
        @own_connection = true
      end
      @own_date = true if HTTP.named?(name, "date")
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
      elsif @body.bytesize + data.bytesize > LIMIT
        flush # (data goes straight out: the buffer never grows past LIMIT and stays that size)
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
      @headers << "content-type" << "text/plain; charset=utf-8" unless @sent || header?("content-type") # (known good: no checks)
      write(s)
    end

    # Sends the head (once) and what is buffered; the rest streams.
    def flush
      unless @sent
        @sent = true
        @streaming = true
        @wire.write_head(@status, @headers, -1, date, @own_connection)
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
      @wire.write_head(@status, @headers, -2, date, @own_connection)
      @wire.sock
    end

    # Replaces the response with an error answer, through the server's
    # errors object. A head on the wire cannot be replaced: IOError.
    def fail(status, message)
      raise IOError, "response already started" if @sent
      allow = +""
      allow << header_value("allow")
      @headers.clear
      @own_date = false
      @own_connection = false
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
        @wire.write_head(@status, @headers, @body.bytesize, date, @own_connection)
        @wire.write(@body) unless @wire.head_only?
      end
      nil
    end

    private

    # The server's Date, or "" when the app set its own.
    def date = @own_date ? "" : @server.date
  end

  # The default errors object: the message as plain text.
  class PlainErrors
    def call(status, message, res)
      res.text(message)
      res.text("\n")
    end
  end
end
