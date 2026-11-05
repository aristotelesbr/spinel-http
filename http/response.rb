module HTTP
  # Collects status, headers and body. The connection writes it once, with
  # Content-Length; past the buffer limit it switches to chunked and streams.
  class Response
    attr_reader :status, :bytes_written

    def initialize
      @status = 200
      @headers = {}
      @body = +""
      @bytes_written = 0
      @sent_head = false
      @conn = nil
    end

    def reset(conn)
      @status = 200
      @headers.clear
      @body.clear
      @bytes_written = 0
      @sent_head = false
      @conn = conn
      nil
    end

    def status=(code)
      raise ArgumentError, "status already sent" if @sent_head
      @status = code
    end

    def set_header(name, value)
      raise ArgumentError, "headers already sent" if @sent_head
      @headers[name.downcase] = value
      nil
    end

    def header(name)
      @headers.fetch(name, "")
    end

    def each_header
      @headers.each { |k, v| yield k, v }
      nil
    end

    def content_type=(value)
      set_header("content-type", value)
    end

    def write(s)
      @body << s
      @bytes_written += s.bytesize
      flush if @conn && @body.bytesize >= Connection::BUFFER_LIMIT
      nil
    end

    def text(s)
      set_header("content-type", "text/plain; charset=utf-8") unless @sent_head || @headers.key?("content-type")
      write(s)
    end

    # Sends what is buffered as a chunk (the head first, once).
    def flush
      return nil unless @conn
      @sent_head = @conn.start_chunked(self) unless @sent_head
      @conn.write_chunk(@body) unless @body.empty?
      @body.clear
      nil
    end

    def sent_head? = @sent_head
    def body = @body

    def drop_body
      @body.clear
      nil
    end

    # Used by the server when an error replaces whatever was set.
    def replace(status, message)
      @status = status
      @headers.clear
      @body.clear
      @bytes_written = 0
      text("#{message}\n")
    end
  end
end
