require_relative "params"

module SpinelHTTP
  # Seconds on the monotonic clock: the one req.started_at is read from,
  # so SpinelHTTP.now - req.started_at is the time spent on the request so far.
  def self.now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The request being served: a view over the connection's buffer, reused
  # for every request the connection carries. Method and path are ready;
  # the rest becomes a String only when asked for.
  class Request
    # A body read whole up to this size keeps its buffer for the next
    # request of the connection; a bigger one is let go.
    KEEP_BODY = 65536

    attr_reader :method, :path

    # SpinelHTTP.now when the head of this request had been read.
    attr_reader :started_at

    attr_accessor :context

    def initialize(wire)
      @wire = wire
      @method = "GET"
      @path = String.new(capacity: 256)
      @params = { "" => "" }
      @body = String.new(capacity: 1024)
      @body_read = false
      @context = nil
      @started_at = 0.0
      @query_params = Params.new
      @form_params = Params.new
      @query_parsed = false
      @form_parsed = false
    end

    def reset
      @started_at = SpinelHTTP.now
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
      @query_parsed = false
      @form_parsed = false
      nil
    end

    # Called by the server once the answer is out: a body bigger than
    # KEEP_BODY is let go (with the form fields that point into it) rather
    # than kept while the connection waits for its next request.
    def done
      return nil if @body.bytesize <= KEEP_BODY
      @body = String.new(capacity: 1024)
      @form_params.parse("")
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

    # The fields of the query string, decoded on first use (SpinelHTTP::Params,
    # valid for this request).
    def query_params
      unless @query_parsed
        @query_parsed = true
        @query_params.parse(query)
      end
      @query_params
    end

    # The fields of an application/x-www-form-urlencoded body, read and
    # decoded on first use; none for any other content type.
    def form_params
      unless @form_parsed
        @form_parsed = true
        if header("content-type").downcase.start_with?("application/x-www-form-urlencoded")
          @form_params.parse(body)
        else
          @form_params.parse("")
        end
      end
      @form_params
    end

    # A :name segment of the route that matched; "" when absent.
    def param(name) = @params.fetch(name, "")
  end
end
