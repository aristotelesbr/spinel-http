module SpinelHTTP
  REASONS = {
    100 => "Continue", 101 => "Switching Protocols",
    200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content",
    206 => "Partial Content",
    301 => "Moved Permanently", 302 => "Found", 303 => "See Other",
    304 => "Not Modified", 307 => "Temporary Redirect", 308 => "Permanent Redirect",
    400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 406 => "Not Acceptable",
    408 => "Request Timeout", 409 => "Conflict", 410 => "Gone",
    411 => "Length Required", 412 => "Precondition Failed", 413 => "Content Too Large",
    415 => "Unsupported Media Type", 416 => "Range Not Satisfiable",
    417 => "Expectation Failed", 422 => "Unprocessable Content",
    428 => "Precondition Required", 429 => "Too Many Requests",
    431 => "Request Header Fields Too Large",
    500 => "Internal Server Error", 501 => "Not Implemented", 502 => "Bad Gateway",
    503 => "Service Unavailable", 504 => "Gateway Timeout",
    505 => "HTTP Version Not Supported",
  }

  def self.reason(status)
    REASONS.fetch(status, "Unknown")
  end

  # (Built from a literal seed: a Hash made by to_h is untyped in Spinel.)
  def self.build_status_lines
    lines = { 200 => "HTTP/1.1 200 OK\r\n" }
    REASONS.each { |code, text| lines[code] = "HTTP/1.1 #{code} #{text}\r\n" }
    lines
  end

  STATUS_LINES = build_status_lines

  # "HTTP/1.1 200 OK\r\n", built once per known status.
  def self.status_line(status)
    STATUS_LINES[status] || "HTTP/1.1 " + status.to_s + " " + reason(status) + "\r\n"
  end

  # Raised by handlers and guards; the server answers with its status.
  class Error < StandardError
    attr_reader :status

    def initialize(status, message = SpinelHTTP.reason(status))
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
