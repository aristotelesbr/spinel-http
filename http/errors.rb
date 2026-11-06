module HTTP
  REASONS = {
    100 => "Continue", 101 => "Switching Protocols",
    200 => "OK", 201 => "Created", 204 => "No Content",
    304 => "Not Modified",
    400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout",
    411 => "Length Required", 413 => "Content Too Large", 417 => "Expectation Failed",
    422 => "Unprocessable Content", 431 => "Request Header Fields Too Large",
    500 => "Internal Server Error", 501 => "Not Implemented",
    503 => "Service Unavailable",
  }

  def self.reason(status)
    REASONS.fetch(status, "Unknown")
  end

  # Raised by handlers and guards; the server answers with its status.
  class Error < StandardError
    attr_reader :status

    def initialize(status, message = HTTP.reason(status))
      super(message)
      @status = status
    end
  end

  class BadRequest < Error
    def initialize(message = "bad request") = super(400, message)
  end

  class Unauthorized < Error
    def initialize(message = "unauthorized") = super(401, message)
  end

  class NotFound < Error
    def initialize(message = "not found") = super(404, message)
  end

  class MethodNotAllowed < Error
    def initialize(message = "method not allowed") = super(405, message)
  end
end
