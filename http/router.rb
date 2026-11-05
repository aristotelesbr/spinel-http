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
    attr_reader :text

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
    end

    def params? = @names.any? { |n| !n.empty? }

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

  # The routes with {params}, as a radix tree: each node holds a run of
  # literal bytes, children are picked by their first byte, and a param
  # child takes the bytes up to the next "/". A literal child is tried
  # before the param one. Looking a path up builds no String; the time
  # grows with the path, not with the number of routes.
  class Radix
    attr_accessor :prefix, :value

    def initialize(prefix)
      @prefix = prefix
      @first = [0]
      @first.clear
      @kids = [self]
      @kids.clear
      @param = nil
      @value = -1
    end

    # Adds a pattern ("/posts/{id}/comments") ending in `value`.
    def add(text, value)
      node = self
      pos = 0
      while pos < text.bytesize
        open = text.index("{", pos) || text.bytesize
        node = node.insert(text.byteslice(pos, open - pos)) if open > pos
        break if open == text.bytesize
        node = node.param_node
        pos = text.index("}", open) + 1
      end
      node.value = value
      nil
    end

    def insert(lit)
      return self if lit.empty?
      b = lit.getbyte(0)
      k = @first.index(b)
      if k.nil?
        n = Radix.new(lit)
        @first << b
        @kids << n
        return n
      end
      child = @kids[k]
      common = 0
      max = child.prefix.bytesize < lit.bytesize ? child.prefix.bytesize : lit.bytesize
      common += 1 while common < max && child.prefix.getbyte(common) == lit.getbyte(common)
      if common < child.prefix.bytesize
        mid = Radix.new(child.prefix.byteslice(0, common))
        child.prefix = child.prefix.byteslice(common, child.prefix.bytesize - common)
        mid.adopt(child)
        @kids[k] = mid
        child = mid
      end
      child.insert(lit.byteslice(common, lit.bytesize - common))
    end

    def adopt(n)
      @first << n.prefix.getbyte(0)
      @kids << n
      nil
    end

    def param_node
      @param = Radix.new("") if @param.nil?
      @param
    end

    # The value of the route matching path[pos..], -1 when none does.
    def lookup(path, pos)
      plen = @prefix.bytesize
      return -1 if path.bytesize - pos < plen
      i = 0
      while i < plen
        return -1 unless path.getbyte(pos + i) == @prefix.getbyte(i)
        i += 1
      end
      pos += plen
      return @value if pos == path.bytesize && @value >= 0
      if pos < path.bytesize
        v = lookup_kids(path, pos)
        return v if v >= 0
      end
      return -1 if @param.nil? || pos == path.bytesize
      stop = pos
      stop += 1 while stop < path.bytesize && path.getbyte(stop) != 47
      return -1 if stop == pos
      return @param.value if stop == path.bytesize
      @param.lookup_kids(path, stop)
    end

    def lookup_kids(path, pos)
      b = path.getbyte(pos)
      k = 0
      while k < @first.size
        return @kids[k].lookup(path, pos) if @first[k] == b
        k += 1
      end
      -1
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
      @exact = { "" => PathGroup.new(Pattern.new("")) }
      @exact.clear
      @tree = Radix.new("")
      @param_groups = []
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
      @groups.each do |group|
        if group.pattern.params?
          @tree.add(group.pattern.text, @param_groups.size)
          @param_groups << group
        else
          @exact[group.pattern.text] = group
        end
      end
      @ready = true
      nil
    end

    def call(req, res)
      prepare unless @ready # (the server prepares before accepting)
      path = req.path
      group = @exact[path]
      if group.nil?
        k = @tree.lookup(path, 0)
        group = @param_groups[k] if k >= 0
      end
      route = group&.route_for(req.method)
      if route
        group.pattern.extract(path, req)
        run(route.steps, req, res) { route.handler.call(req, res) }
        return nil
      end
      run(area_steps(path), req, res) do
        raise NotFound if group.nil?
        res.header("allow", group.allow)
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
        res.fail(e.status, e.message)
      rescue StandardError => e
        error = e
        warn "#{e.class}: #{e.message}"
        res.fail(500, "internal server error")
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
