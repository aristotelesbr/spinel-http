module HTTP
  # One per connection, reset for every request it carries.
  class Request
    attr_reader :method, :target, :path, :query, :version, :body
    attr_accessor :state

    def initialize
      @method = ""
      @target = ""
      @path = ""
      @query = ""
      @version = ""
      @headers = {}
      @params = {}
      @body = +""
      @state = nil
    end

    def reset(method, target, version)
      @method = method
      @target = target
      q = target.index("?")
      if q
        @path = target[0, q]
        @query = target[q + 1, target.size - q - 1]
      else
        @path = target
        @query = ""
      end
      @version = version
      @headers.clear
      @params.clear
      @body.clear
      @state = nil
      nil
    end

    # Header names are kept lowercase.
    def add_header(name, value)
      @headers[name] = value
      nil
    end

    def header(name)
      @headers.fetch(name, "")
    end

    def header?(name)
      @headers.key?(name)
    end

    def add_param(name, value)
      @params[name] = value
      nil
    end

    def param(name)
      @params.fetch(name, "")
    end

    def append_body(chunk)
      @body << chunk
      nil
    end

    def keep_alive?
      conn = header("connection").downcase
      @version == "HTTP/1.0" ? conn == "keep-alive" : conn != "close"
    end
  end
end
