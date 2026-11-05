module HTTP
  # A guard plus whether it has `after`, decided at boot.
  class Step
    attr_reader :guard, :closes

    def initialize(guard)
      @guard = guard
      @closes = guard.respond_to?(:after) ? true : false
    end
  end

  # A path pattern split at boot: literal segments and {param} segments.
  class Pattern
    attr_reader :text, :rank

    def initialize(text)
      @text = text
      @segs = []
      @names = []
      text.split("/").each do |seg|
        next if seg.empty?
        if seg.start_with?("{") && seg.end_with?("}")
          @segs << ""
          @names << seg[1, seg.size - 2]
        else
          @segs << seg
          @names << ""
        end
      end
      # literal before param, position by position
      @rank = @names.map { |n| n.empty? ? "0" : "1" }.join
    end

    # Matches without allocating: walks the path segment by segment.
    def match?(path)
      return false unless path.getbyte(0) == 47
      pos = 1
      i = 0
      n = @segs.size
      return path.size == 1 if n == 0
      while i < n
        return false if pos >= path.size
        stop = path.index("/", pos) || path.size
        len = stop - pos
        return false if len == 0
        lit = @segs[i]
        if @names[i].empty?
          return false unless len == lit.size && path.index(lit, pos) == pos
        end
        pos = stop + 1
        i += 1
      end
      pos >= path.size + 1
    end

    def extract(path, req)
      pos = 1
      i = 0
      while i < @segs.size
        stop = path.index("/", pos) || path.size
        req.add_param(@names[i], path[pos, stop - pos]) unless @names[i].empty?
        pos = stop + 1
        i += 1
      end
      nil
    end
  end

  class Route
    attr_reader :verb, :key, :handler, :steps

    def initialize(verb, key, handler)
      @verb = verb
      @key = key
      @handler = handler
      @steps = []
    end

    def attach(step)
      @steps << step
      nil
    end
  end

  # Every route of one pattern, by verb.
  class PathGroup
    attr_reader :pattern, :routes, :allow

    def initialize(pattern)
      @pattern = pattern
      @routes = []
      @allow = ""
    end

    def add(route)
      @routes << route
      nil
    end

    def seal
      verbs = @routes.map(&:verb)
      verbs << "HEAD" if verbs.include?("GET") && !verbs.include?("HEAD")
      verbs << "OPTIONS"
      @allow = verbs.join(", ")
      nil
    end

    def route_for(method)
      want = method == "HEAD" ? "GET" : method
      @routes.each { |r| return r if r.verb == want || r.verb == method }
      nil
    end
  end

  class Area
    attr_reader :prefix, :step, :except, :covering

    def initialize(prefix, guard, except)
      @prefix = prefix
      @step = Step.new(guard)
      @except = except
      @covering = []
    end
  end

  # routes.handle "GET /posts/{id}", Guard.new, ..., Handler.new
  # routes.use "/admin", Guard.new, except: ["POST /admin/login"]
  class Router
    VERBS = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]

    def initialize
      @groups = []
      @inline = []
      @areas = []
      @no_steps = []
      @ready = false
    end

    def handle(spec, *objects)
      raise ArgumentError, "route #{spec.inspect} needs a handler" if objects.empty?
      space = spec.index(" ")
      raise ArgumentError, "route needs a verb: #{spec.inspect}" if space.nil?
      verb = spec[0, space]
      raise ArgumentError, "unknown verb #{verb.inspect} in #{spec.inspect}" unless VERBS.include?(verb)
      text = spec[space + 1, spec.size - space - 1]
      group = @groups.find { |g| g.pattern.text == text }
      if group.nil?
        group = PathGroup.new(Pattern.new(text))
        @groups << group
      end
      route = Route.new(verb, spec, objects[objects.size - 1])
      group.add(route)
      @inline << [route, objects[0, objects.size - 1]]
      nil
    end

    def use(prefix, guard, except: [])
      @areas << Area.new(prefix, guard, except)
      nil
    end

    # Resolves guards, Allow and precedence once; the server calls it
    # before the first request.
    def prepare
      return nil if @ready
      keys = []
      @groups.each { |g| g.routes.each { |r| keys << r.key } }
      @areas.each do |area|
        area.except.each do |key|
          raise ArgumentError, "except: #{key.inspect} is not a registered route" unless keys.include?(key)
        end
      end
      @groups.each do |group|
        group.seal
        group.routes.each do |route|
          @areas.each do |area|
            next unless Router.covers?(area.prefix, group.pattern.text)
            next if area.except.include?(route.key)
            route.attach(area.step)
          end
        end
      end
      @inline.each { |pair| pair[1].each { |g| pair[0].attach(Step.new(g)) } }
      @areas.each do |area|
        @areas.each { |other| area.covering << other.step if Router.covers?(other.prefix, area.prefix) }
      end
      @groups = @groups.sort_by { |g| g.pattern.rank }
      @ready = true
      nil
    end

    def call(req, res)
      prepare unless @ready # (the server prepares before accepting)
      path = req.path
      group = nil
      @groups.each do |g|
        if g.pattern.match?(path)
          group = g
          break
        end
      end
      route = group&.route_for(req.method)
      if route
        group.pattern.extract(path, req)
        run(route.steps, req, res) { route.handler.call(req, res) }
        return nil
      end
      run(area_steps(path), req, res) do
        raise NotFound if group.nil?
        res.set_header("allow", group.allow)
        if req.method == "OPTIONS"
          res.status = 204
        else
          raise MethodNotAllowed
        end
      end
      nil
    end

    # "/api" covers "/api" and "/api/...", not "/apix".
    def self.covers?(prefix, path)
      return true if prefix == "/"
      return false unless path.start_with?(prefix)
      path.size == prefix.size || path.getbyte(prefix.size) == 47
    end

    private

    # The areas covering a path are those covering the deepest area that
    # matches it, so a list per area answers without building one.
    def area_steps(path)
      steps = @no_steps
      depth = -1
      @areas.each do |area|
        next unless Router.covers?(area.prefix, path) && area.prefix.size > depth
        depth = area.prefix.size
        steps = area.covering
      end
      steps
    end

    # Guards in order, then the block; an error becomes the response first,
    # so `after` (of every guard whose `check` ran, in reverse, always) sees
    # the final status and can still set headers.
    def run(steps, req, res)
      opened = 0
      error = nil
      begin
        steps.each do |step|
          step.guard.check(req, res)
          opened += 1
        end
        yield
      rescue HTTP::Error => e
        error = e
        HTTP.respond_error(res, e)
      rescue StandardError => e
        error = e
        HTTP.respond_crash(res, e)
      ensure
        i = opened - 1
        while i >= 0
          step = steps[i]
          step.guard.after(req, res, error) if step.closes
          i -= 1
        end
      end
      nil
    end
  end
end
