require "socket"
require "time"
require_relative "errors"
require_relative "request"
require_relative "response"
require_relative "connection"

module HTTP
  # Accepts connections and serves each one on its own thread. The handler is
  # any object with `call(req, res)`.
  class Server
    attr_reader :idle_timeout, :header_timeout, :max_header_bytes, :max_body_bytes, :port

    def initialize(handler, host: "127.0.0.1", port: 8080, observer: nil,
                   idle_timeout: 5.0, header_timeout: 10.0, shutdown_timeout: 10.0,
                   max_header_bytes: 8192, max_body_bytes: 1_048_576)
      @handler = handler
      @host = host
      @port = port
      @observer = observer
      @idle_timeout = idle_timeout
      @header_timeout = header_timeout
      @shutdown_timeout = shutdown_timeout
      @max_header_bytes = max_header_bytes
      @max_body_bytes = max_body_bytes
      @stopping = false
      @active = 0
      @lock = Mutex.new
      @date = ""
      @date_at = -1
    end

    # Serves until #shutdown, SIGTERM or SIGINT; then waits for the requests
    # in progress. Yields the bound port once listening.
    def listen
      listener = TCPServer.new(@host, @port)
      @port = listener.addr[1]
      Signal.trap("TERM") { @stopping = true }
      Signal.trap("INT") { @stopping = true }
      yield @port if block_given?
      until @stopping
        next if IO.select([listener], nil, nil, 0.2).nil?
        sock = listener.accept
        @lock.synchronize { @active += 1 }
        Thread.new do
          Connection.new(sock, self).serve
          @lock.synchronize { @active -= 1 }
        end
      end
      listener.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_timeout
      while @lock.synchronize { @active } > 0 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
      end
      nil
    end

    def shutdown
      @stopping = true
      nil
    end

    def stopping? = @stopping

    # Runs the handler; an HTTP::Error becomes its status, anything else a 500.
    def dispatch(req, res)
      @handler.call(req, res)
      nil
    rescue HTTP::Error => e
      raise IOError, "response already started" if res.sent_head?
      allow = res.header("allow")
      res.replace(e.status, e.message)
      res.set_header("allow", allow) unless allow.empty?
      nil
    rescue StandardError => e
      raise IOError, "response already started" if res.sent_head?
      warn "#{e.class}: #{e.message}"
      res.replace(500, "internal server error")
      nil
    end

    def finished(req, res)
      @observer&.finished(req, res)
      nil
    end

    # The Date header, formatted once a second.
    def date
      t = Time.now
      s = t.to_i
      if s != @date_at
        @date = t.httpdate
        @date_at = s
      end
      @date
    end
  end
end
