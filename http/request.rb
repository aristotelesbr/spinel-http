module HTTP
  # The request being served: a view over the connection's buffer, reused
  # for every request the connection carries. Method and path are ready;
  # the rest becomes a String only when asked for.
  class Request
    attr_reader :method, :path
    attr_accessor :context

    def initialize(wire)
      @wire = wire
      @method = "GET"
      @path = String.new(capacity: 256)
      @params = { "" => "" }
      @body = String.new(capacity: 1024)
      @body_read = false
      @context = nil
    end

    def reset
      @method = @wire.method
      from = @wire.target_from
      to = @wire.target_to
      q = @wire.byteindex("?", from)
      stop = q && q < to ? q : to
      @path.replace(@wire.byteslice(from, stop - from))
      @params.clear
      @body.replace("")
      @body_read = false
      @context = nil
      nil
    end

    # The request target as sent ("/posts/1?x=1").
    def target = @wire.byteslice(@wire.target_from, @wire.target_to - @wire.target_from)

    # The query string without "?", "" when there is none.
    def query
      to = @wire.target_to
      q = @wire.byteindex("?", @wire.target_from)
      return "" if q.nil? || q >= to
      @wire.byteslice(q + 1, to - q - 1)
    end

    def version = @wire.version == 1 ? "HTTP/1.1" : "HTTP/1.0"

    # Header names are matched without regard to case; "" when absent.
    def header(name) = @wire.header(name)
    def header?(name) = @wire.header?(name)
    def each_header(&block) = @wire.each_header(&block)

    # Declared body length; -1 for a chunked body.
    def content_length = @wire.content_length

    # The body in pieces, as it arrives; each piece is valid until the next.
    def each_chunk
      while @wire.read_body_chunk > 0
        yield @wire.chunk
      end
      nil
    end

    # The whole body (bounded by max_body_bytes), read on first use.
    def body
      unless @body_read
        @body_read = true
        while @wire.read_body_chunk > 0
          @body << @wire.chunk
        end
      end
      @body
    end

    def add_param(name, value)
      @params[name] = value
      nil
    end

    # A :name segment of the route that matched; "" when absent.
    def param(name) = @params.fetch(name, "")
  end
end
