require_relative "server"

module HTTP
  # Calls a handler without a socket, as the server would, and returns the
  # Response: HTTP::Testing.request(app, "GET /posts/1").
  module Testing
    def self.request(handler, line, headers: {}, body: "")
      space = line.index(" ")
      raise ArgumentError, "request needs a verb: #{line.inspect}" if space.nil?
      handler.prepare if handler.respond_to?(:prepare)
      req = Request.new
      req.reset(line[0, space], line[space + 1, line.size - space - 1], "HTTP/1.1")
      headers.each { |k, v| req.add_header(k.downcase, v) }
      req.append_body(body) unless body.empty?
      res = Response.new
      res.reset(nil)
      HTTP.dispatch(handler, req, res)
      res.drop_body if req.method == "HEAD"
      res
    end
  end
end
