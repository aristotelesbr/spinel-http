module HTTP
  # Observer that prints one line per request: method, target, status,
  # body bytes.
  class AccessLog
    def initialize(io = $stdout)
      @io = io
    end

    def finished(req, res)
      @io.puts "#{req.method} #{req.target} #{res.status} #{res.bytes_written}"
      nil
    end
  end
end
