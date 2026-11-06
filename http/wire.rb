module HTTP
  # The socket side of one connection: reads heads and bodies through its
  # own buffer and writes responses through another. Holds every limit the
  # server promises: head size and grammar, number sizes, time to send a
  # head, idle time between requests and time per body read.
  #
  # The head is kept as offsets into the buffer; a header becomes a String
  # only when asked for.
  class Wire
    METHODS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"]
    READ = 16384
    CHUNK = 65536
    # A chunk bigger than this goes out in its own write rather than
    # through @out, which would grow to it and keep that size.
    OUT_INLINE = 4096
    # A body the app left unread is read and dropped up to this much so the
    # connection can be reused; past it the connection is closed instead.
    MAX_DRAIN = 262144
    # Seconds a closing connection keeps reading (and dropping) what the
    # peer still sends, after its answer, before it closes.
    LINGER = 0.5
    # A body has header_timeout plus one second per MIN_RATE bytes received
    # to arrive: a slow upload goes on, a trickle is cut.
    MIN_RATE = 65536.0

    attr_reader :sock, :method, :version, :sp1, :sp2

    def initialize(sock, limits)
      @sock = sock
      @limits = limits
      @buf = String.new(capacity: READ)
      @chunk = String.new(capacity: CHUNK)
      @out = String.new(capacity: 4096)
      @offs = [0]
      @start = 0
      @method = "GET"
      @version = 1
      @sp1 = 0
      @sp2 = 0
      @line_end = 0
      @keep = true
      @mode = 0
      @left = 0
      @left_declared = 0
      @total = 0
      @received = 0
      @body_from = 0.0
      @state = 0
      @raw = false
      @continue = false
      @writing_since = 0
    end

    # The server's tick a write in progress started in; 0 when none is.
    def writing_since = @writing_since

    # Reads the next head. 0 when it is in, -1 when the peer closed or went
    # quiet (close without answering), or the status to answer before
    # closing.
    def read_head
      compact
      skip_empty_lines
      if @buf.empty?
        return -1 if @sock.wait_readable(@limits.idle_timeout).nil?
        return -1 unless fill(0.0)
        skip_empty_lines
      end
      deadline = now + @limits.header_timeout
      scanned = 0
      loop do
        stop = @buf.byteindex("\r\n\r\n")
        limit = stop.nil? ? @buf.bytesize : stop
        return 400 if bare_lf?(scanned, limit)
        scanned = limit
        if stop
          return 431 if stop > @limits.max_header_bytes
          return parse_head(stop)
        end
        return 431 if @buf.bytesize > @limits.max_header_bytes
        left = deadline - now
        return -1 if left <= 0
        return -1 unless fill(left)
      end
    end

    def keep_alive? = @keep
    def no_reuse = (@keep = false)
    def head_only? = @method == "HEAD"
    def target_from = @sp1 + 1
    def target_to = @sp2

    def byteslice(from, len) = @buf.byteslice(from, len)
    def byteindex(s, from) = @buf.byteindex(s, from)

    # The value of a header as a new String, "" when absent.
    def header(name)
      k = find(name.to_s, 0)
      k < 0 ? "" : @buf.byteslice(@offs[k + 2], @offs[k + 3] - @offs[k + 2])
    end

    # (name.to_s: a public method no call site binds gets an untyped name,
    # and passing that on would widen find/same? for every caller.)
    def header?(name) = find(name.to_s, 0) >= 0

    def each_header
      k = 0
      while k < @offs.size
        yield @buf.byteslice(@offs[k], @offs[k + 1] - @offs[k]), @buf.byteslice(@offs[k + 2], @offs[k + 3] - @offs[k + 2])
        k += 4
      end
      nil
    end

    # Length of the body when the head declared one, -1 for chunked, 0 when
    # there is none.
    def content_length = @mode == 2 ? -1 : @left_declared

    # Puts the next piece of the body in #chunk and answers its size; 0 at
    # the end of the body. Raises HTTP::Error on a body that breaks the
    # limits or the grammar, or that stops coming.
    def read_body_chunk
      return 0 if @mode == 0
      if @continue
        @continue = false
        send_all("HTTP/1.1 100 Continue\r\n\r\n")
      end
      return read_length_chunk if @mode == 1
      read_chunked_chunk
    end

    def chunk = @chunk

    # Reads what is left of the body so the next request starts clean. 0
    # when it did; otherwise the status the body deserves (400, 408, 413),
    # and the connection is not reused.
    # A client still waiting for "100 Continue" never sent its body, and a
    # body over MAX_DRAIN is not worth reading: in both cases the
    # connection is closed instead.
    def drain_body
      return 0 if @mode == 0
      return give_up if @continue || (@mode == 1 && @left > MAX_DRAIN)
      drained = 0
      loop do
        k = read_body_chunk
        break if k == 0
        drained += k
        return give_up if drained > MAX_DRAIN
      end
      0
    rescue HTTP::Error => e
      @keep = false
      e.status
    end

    def give_up
      @continue = false
      @keep = false
      0
    end

    # Whether the peer may still have bytes on the way (a body or a
    # request not read): closing then should go through #linger.
    def unread? = @mode != 0 || @buf.bytesize > @start

    # Before closing on a peer that may still be sending: stop writing,
    # then read and drop what comes for up to LINGER seconds, so the close
    # does not reset the connection under an answer the peer has not read.
    # (shutdown, not close_write: in Spinel close_write raises on a
    # socket, spinel-findings 193.)
    def linger
      @sock.shutdown(Socket::SHUT_WR)
      deadline = now + LINGER
      loop do
        left = deadline - now
        break if left <= 0 || @sock.wait_readable(left).nil?
        @sock.readpartial(READ, @chunk)
      end
      nil
    rescue IOError, SystemCallError
      nil
    end

    # The head of a response. length -1 means chunked, -2 a head before the
    # socket is handed over (no length, no connection header), -3 a body
    # sent until the connection closes (HTTP/1.0 streaming), -4 no body at
    # all (1xx, 204, 304). date "" leaves out the server's (the app set its
    # own), and so does own_connection with the connection header. With
    # with_body, body goes out with the head, in the same write when it
    # fits in OUT_INLINE. Once a final answer is out, a pending "100
    # Continue" is not sent any more and the body it held back will not
    # come: the connection closes.
    def write_head(status, headers, length, date, own_connection, body, with_body)
      if @continue
        @continue = false
        @keep = false
      end
      @out.replace("HTTP/1.1 ")
      append_int(@out, status)
      @out << " " << HTTP.reason(status) << "\r\n"
      i = 0
      while i < headers.size
        @out << headers[i] << ": " << headers[i + 1] << "\r\n"
        i += 2
      end
      @out << "date: " << date << "\r\n" unless date.empty?
      if length == -2
        @out << "\r\n"
        send_all(@out)
        return nil
      end
      if length == -1 && @version == 0
        length = -3
      end
      if length == -1
        @out << "transfer-encoding: chunked\r\n"
      elsif length == -4
        nil
      elsif length == -3
        @raw = true
        @keep = false
      else
        @out << "content-length: "
        append_int(@out, length)
        @out << "\r\n"
      end
      @out << (@keep ? "connection: keep-alive\r\n" : "connection: close\r\n") unless own_connection
      @out << "\r\n"
      if !with_body || body.empty?
        send_all(@out)
      elsif body.bytesize <= OUT_INLINE
        @out << body
        send_all(@out)
      else
        send_all(@out)
        send_all(body)
      end
      nil
    end

    def write_chunk(data)
      return nil if data.empty?
      if @raw
        send_all(data)
        return nil
      end
      @out.replace("")
      append_hex(@out, data.bytesize)
      @out << "\r\n"
      if data.bytesize > OUT_INLINE
        send_all(@out)
        send_all(data)
        send_all("\r\n")
      else
        @out << data << "\r\n"
        send_all(@out)
      end
      nil
    end

    def end_chunks
      send_all("0\r\n\r\n") unless @raw
      @raw = false
      nil
    end

    private

    # Writes all of `data`. The deadline is kept off this path: the write
    # notes the server's tick it started in, and the server's watchdog
    # closes a connection whose write has spanned two ticks (a peer that
    # stopped reading), which makes this write raise IOError.
    def send_all(data)
      @writing_since = @limits.tick
      @sock.write(data)
      @writing_since = 0
      nil
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def compact
      if @start >= @buf.bytesize
        @buf.replace("")
      elsif @start > 0
        @buf.replace(@buf.byteslice(@start, @buf.bytesize - @start))
      end
      @start = 0
      nil
    end

    # Empty lines before a request line are allowed and ignored.
    def skip_empty_lines
      while @buf.byteindex("\r\n", @start) == @start
        @start += 2
      end
      compact if @start > 0
      nil
    end

    # Appends what one read brings; false at the end of the stream or when
    # nothing comes within `wait` seconds (0.0: data is known to be there).
    def fill(wait)
      return false if wait > 0.0 && @sock.wait_readable(wait).nil?
      @sock.readpartial(READ, @chunk)
      @buf << @chunk
      true
    rescue EOFError
      false
    end

    # Waits for at least `want` bytes after @start, within the body time.
    def fill_to(want)
      while @buf.bytesize - @start < want
        fill_body
      end
      nil
    end

    # (Compacts first once READ bytes are behind @start: a body read
    # through @buf would otherwise grow it to the body's size, and the
    # connection would keep that much for as long as it lives.)
    def fill_body
      compact if @start >= READ
      left = @body_from + @limits.header_timeout + @received / MIN_RATE - now
      raise HTTP::Error.new(408, "body timeout") if left <= 0 || !fill(left)
      nil
    end

    def bare_lf?(from, to)
      i = @buf.byteindex("\n", from)
      while i && i < to
        return true if i == 0 || @buf.getbyte(i - 1) != 13
        i = @buf.byteindex("\n", i + 1)
      end
      false
    end

    def parse_head(stop)
      @line_end = @buf.byteindex("\r\n")
      @sp1 = @buf.byteindex(" ") || -1
      return 400 if @sp1 <= 0 || @sp1 > @line_end
      @sp2 = @buf.byteindex(" ", @sp1 + 1) || -1
      return 400 if @sp2 < 0 || @sp2 > @line_end || @sp2 == @sp1 + 1
      return 400 unless upper?(0, @sp1)
      return 400 unless visible?(@sp1 + 1, @sp2)
      first = @buf.getbyte(@sp1 + 1)
      return 400 unless first == 47 || (first == 42 && @sp2 == @sp1 + 2)
      status = parse_version(@sp2 + 1, @line_end)
      return status if status > 0
      @method = known_method
      return 501 if @method.empty?
      @offs.clear
      pos = @line_end + 2
      while pos < stop + 2
        nl = @buf.byteindex("\r\n", pos)
        b = @buf.getbyte(pos)
        return 400 if b == 32 || b == 9
        colon = @buf.byteindex(":", pos)
        return 400 if colon.nil? || colon > nl || colon == pos
        return 400 unless token?(pos, colon)
        vs = colon + 1
        vs += 1 while vs < nl && (@buf.getbyte(vs) == 32 || @buf.getbyte(vs) == 9)
        ve = nl
        ve -= 1 while ve > vs && (@buf.getbyte(ve - 1) == 32 || @buf.getbyte(ve - 1) == 9)
        return 400 unless field_value?(vs, ve)
        @offs << pos << colon << vs << ve
        pos = nl + 2
      end
      @start = stop + 4
      status = check_framing
      return status if status > 0
      check_expect
    end

    # "Expect: 100-continue" is answered on the first read of the body (the
    # client holds the body back until then); any other expectation is a
    # 417.
    def check_expect
      @continue = false
      k = find("expect", 0)
      return 0 if k < 0
      return 417 unless same?(@offs[k + 2], @offs[k + 3], "100-continue", true)
      @continue = @version == 1 && @mode != 0
      0
    end

    def parse_version(from, to)
      return 400 unless to - from == 8 && same?(from, from + 5, "HTTP/", false)
      return 505 unless @buf.getbyte(from + 5) == 49 && @buf.getbyte(from + 6) == 46
      minor = @buf.getbyte(from + 7)
      return 505 unless minor == 48 || minor == 49
      @version = minor - 48
      0
    end

    def known_method
      METHODS.each { |m| return m if same?(0, @sp1, m, false) }
      ""
    end

    # Host, Content-Length and Transfer-Encoding decide where the body ends;
    # any doubt about it is a 400.
    def check_framing
      hosts = count("host")
      return 400 if hosts > 1 || (@version == 1 && hosts == 0)
      lengths = count("content-length")
      te = find("transfer-encoding", 0)
      return 400 if lengths > 1 || (lengths == 1 && te >= 0)
      return 400 if te >= 0 && find("transfer-encoding", te + 4) >= 0
      @keep = @version == 1 ? !value_is?("connection", "close") : value_is?("connection", "keep-alive")
      @total = 0
      @received = 0
      @body_from = now
      @left_declared = 0
      if te >= 0
        return 501 unless same?(@offs[te + 2], @offs[te + 3], "chunked", true)
        @mode = 2
        @state = 0
        @left = 0
        return 0
      end
      if lengths == 0
        @mode = 0
        return 0
      end
      k = find("content-length", 0)
      from = @offs[k + 2]
      to = @offs[k + 3]
      return 400 if from == to
      return 413 if to - from > 12
      n = 0
      while from < to
        d = @buf.getbyte(from) - 48
        return 400 if d < 0 || d > 9
        n = n * 10 + d
        from += 1
      end
      return 413 if n > @limits.max_body_bytes
      @left_declared = n
      @left = n
      @mode = n > 0 ? 1 : 0
      0
    end

    def read_length_chunk
      return 0 if @left <= 0
      k = next_piece
      @left -= k
      @mode = 0 if @left == 0
      k
    end

    # Puts up to @left (at most CHUNK) body bytes in @chunk: what @buf
    # holds, or, when it holds nothing, one read straight into @chunk, so
    # a body does not pass through @buf (and does not grow it).
    def next_piece
      have = @buf.bytesize - @start
      if have > 0
        k = have < @left ? have : @left
        k = CHUNK if k > CHUNK
        take(k)
        return k
      end
      compact
      left = @body_from + @limits.header_timeout + @received / MIN_RATE - now
      raise HTTP::Error.new(408, "body timeout") if left <= 0 || @sock.wait_readable(left).nil?
      @sock.readpartial(@left < CHUNK ? @left : CHUNK, @chunk)
      @received += @chunk.bytesize
      @chunk.bytesize
    rescue EOFError
      raise HTTP::Error.new(408, "body timeout")
    end

    # States: 0 size line, 1 data, 2 CRLF after data, 3 trailers.
    def read_chunked_chunk
      loop do
        if @state == 1
          k = next_piece
          @left -= k
          @state = 2 if @left == 0
          return k
        elsif @state == 2
          fill_to(2)
          raise HTTP::Error.new(400, "bad chunk") unless @buf.byteindex("\r\n", @start) == @start
          @start += 2
          @state = 0
        elsif @state == 0
          nl = line_end(64)
          size = chunk_size(@start, nl)
          @start = nl + 2
          if size == 0
            @state = 3
          else
            @total += size
            raise HTTP::Error.new(413, "body too large") if @total > @limits.max_body_bytes
            @left = size
            @state = 1
          end
        else
          nl = line_end(@limits.max_header_bytes)
          empty = nl == @start
          @start = nl + 2
          if empty
            @mode = 0
            return 0
          end
        end
      end
    end

    # The offset of the CRLF that ends the line at @start, reading more as
    # needed, within `max` bytes.
    def line_end(max)
      loop do
        nl = @buf.byteindex("\r\n", @start)
        return nl if nl && nl - @start <= max
        raise HTTP::Error.new(400, "line too long") if @buf.bytesize - @start > max
        fill_body
      end
    end

    # Hex digits up to ';' or the end; at most 12 digits (the size has to
    # fit, and no body that big is accepted anyway).
    def chunk_size(from, to)
      n = 0
      digits = 0
      while from < to
        b = @buf.getbyte(from)
        break if b == 59
        d = hex(b)
        raise HTTP::Error.new(400, "bad chunk size") if d < 0
        digits += 1
        raise HTTP::Error.new(413, "body too large") if digits > 12
        n = n * 16 + d
        from += 1
      end
      raise HTTP::Error.new(400, "bad chunk size") if digits == 0
      n
    end

    def hex(b)
      return b - 48 if b >= 48 && b <= 57
      return b - 87 if b >= 97 && b <= 102
      return b - 55 if b >= 65 && b <= 70
      -1
    end

    def take(k)
      @chunk.replace(@buf.byteslice(@start, k))
      @start += k
      @received += k
      nil
    end

    def find(name, from)
      k = from
      while k < @offs.size
        return k if same?(@offs[k], @offs[k + 1], name, true)
        k += 4
      end
      -1
    end

    def count(name)
      n = 0
      k = find(name, 0)
      while k >= 0
        n += 1
        k = find(name, k + 4)
      end
      n
    end

    def value_is?(name, value)
      k = find(name, 0)
      k >= 0 && same?(@offs[k + 2], @offs[k + 3], value, true)
    end

    def same?(from, to, want, fold)
      return false unless to - from == want.bytesize
      j = 0
      while j < want.bytesize
        a = @buf.getbyte(from + j)
        b = want.getbyte(j)
        if fold
          a += 32 if a >= 65 && a <= 90
          b += 32 if b >= 65 && b <= 90
        end
        return false unless a == b
        j += 1
      end
      true
    end

    def upper?(from, to)
      while from < to
        b = @buf.getbyte(from)
        return false unless b >= 65 && b <= 90
        from += 1
      end
      true
    end

    def visible?(from, to)
      while from < to
        b = @buf.getbyte(from)
        return false if b <= 32 || b == 127
        from += 1
      end
      true
    end

    # Header names are tokens: letters, digits and !#$%&'*+-.^_`|~
    def token?(from, to)
      while from < to
        b = @buf.getbyte(from)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
             b == 33 || (b >= 35 && b <= 39) || b == 42 || b == 43 || b == 45 || b == 46 ||
             b == 94 || b == 95 || b == 96 || b == 124 || b == 126
        return false unless ok
        from += 1
      end
      true
    end

    # No control bytes in a value except tab.
    def field_value?(from, to)
      while from < to
        b = @buf.getbyte(from)
        return false if (b < 32 && b != 9) || b == 127
        from += 1
      end
      true
    end

    def append_int(out, n)
      d = 1
      t = n
      while t >= 10
        t /= 10
        d += 1
      end
      d.times { out << "0" }
      k = out.bytesize - 1
      d.times do
        out.setbyte(k, 48 + n % 10)
        n /= 10
        k -= 1
      end
      nil
    end

    def append_hex(out, n)
      d = 1
      t = n
      while t >= 16
        t /= 16
        d += 1
      end
      d.times { out << "0" }
      k = out.bytesize - 1
      d.times do
        r = n % 16
        out.setbyte(k, r < 10 ? 48 + r : 87 + r)
        n /= 16
        k -= 1
      end
      nil
    end
  end
end
