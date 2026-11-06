require "socket"
require "time"
require_relative "errors"
require_relative "wire"
require_relative "request"
require_relative "response"
require_relative "router"
require_relative "log"

module HTTP
  # Serves an app: any object with `call(req, res)`. #listen accepts TCP
  # connections and serves each on its own green thread; #serve serves one
  # stream that is already open.
  #
  # An HTTP::Error raised by the app becomes its status; anything else a 500
  # (with the detail on stderr). Both go through the errors object, which
  # answers `call(status, message, res)`.
  class Server
    attr_reader :idle_timeout, :header_timeout, :max_header_bytes, :max_body_bytes, :port

    def initialize(app, host: "127.0.0.1", port: 8080, observer: nil, errors: PlainErrors.new,
                   idle_timeout: 5.0, header_timeout: 10.0, shutdown_timeout: 10.0,
                   max_header_bytes: 16384, max_body_bytes: 1_048_576)
      @app = app
      @host = host
      @port = port
      @observer = observer
      @errors = errors
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
      @tick = 1
      @wires = []
    end

    # Advanced by the watchdog every header_timeout / 2 seconds.
    def tick = @tick

    # Serves until #shutdown, SIGTERM or SIGINT; then waits for the requests
    # in progress. Yields the bound port once listening.
    def listen
      @app.prepare if @app.respond_to?(:prepare)
      listener = TCPServer.new(@host, @port)
      @port = listener.addr[1]
      Signal.trap("TERM") { @stopping = true }
      Signal.trap("INT") { @stopping = true }
      yield @port if block_given?
      watchdog = Thread.new { watch }
      until @stopping
        next if listener.wait_readable(0.2).nil?
        spawn(listener.accept)
      end
      listener.close
      watchdog.join
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @shutdown_timeout
      while @lock.synchronize { @active } > 0 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
      end
      nil
    end

    # Each connection gets its own thread and its own `sock`: a local of the
    # accept loop would be shared by every thread it starts.
    def spawn(sock)
      @lock.synchronize { @active += 1 }
      Thread.new do
        serve(sock)
        @lock.synchronize { @active -= 1 }
      end
      nil
    end

    # Serves the requests of one open connection until either side closes,
    # it goes quiet past idle_timeout, or the server stops.
    def serve(sock)
      wire = Wire.new(sock, self)
      @lock.synchronize { @wires << wire }
      req = Request.new(wire)
      res = Response.new(wire, self, @errors)
      until @stopping
        status = wire.read_head
        break if status < 0
        res.reset
        if status > 0
          wire.no_reuse
          res.fail(status, HTTP.reason(status).downcase)
          res.finish
          wire.linger unless status == 408
          break
        end
        req.reset
        call_app(req, res)
        break if res.taken?
        wire.no_reuse if @stopping
        bad = wire.drain_body
        res.fail(bad, HTTP.reason(bad).downcase) if bad > 0 && !res.sent?
        res.finish
        @observer&.finished(req, res)
        req.done
        next if wire.keep_alive?
        wire.linger if wire.unread? && res.status != 408 # (one too slow to send gets no grace)
        break
      end
    rescue IOError, SystemCallError
      nil
    ensure
      @lock.synchronize { @wires.delete(wire) }
      sock.close unless res&.taken? || sock.closed?
    end

    def shutdown
      @stopping = true
      nil
    end

    def stopping? = @stopping

    # The Date header, formatted once a second.
    def date
      s = Process.clock_gettime(Process::CLOCK_REALTIME).to_i
      if s != @date_at
        @date = Time.at(s).httpdate
        @date_at = s
      end
      @date
    end

    private

    # Every header_timeout / 2: closes the connections whose write started
    # two ticks ago or more, so a peer that does not read cannot hold one
    # (the write raises IOError and the connection ends).
    def watch
      step = @header_timeout / 2
      until @stopping
        sleep step
        @tick += 1
        @lock.synchronize do
          @wires.each do |w|
            since = w.writing_since
            w.sock.close if since > 0 && @tick - since >= 2 && !w.sock.closed?
          end
        end
      end
      nil
    end

    # (Status and message are read in the rescue itself: handing `e` to
    # another method trips a Spinel dispatch bug, spinel-findings 178.)
    def call_app(req, res)
      @app.call(req, res)
      nil
    rescue HTTP::Error => e
      res.error = e
      res.fail(e.status, e.message)
    rescue StandardError => e
      res.error = e
      warn "#{e.class}: #{e.message}"
      res.fail(500, "internal server error")
    end
  end
end
