module HTTP
  # A layer plus which of `before` and `after` it has, decided at boot.
  class Step
    attr_reader :layer, :opens, :closes

    def initialize(layer)
      @layer = layer
      @opens = layer.respond_to?(:before) ? true : false
      @closes = layer.respond_to?(:after) ? true : false
      raise ArgumentError, "#{layer.class} has neither before nor after" unless @opens || @closes
    end
  end

  # A path pattern split at boot: literal segments and :param segments.
  class Pattern
    attr_reader :text, :shape

    def initialize(text)
      @text = text
      @shape = text.split("/", -1).map { |seg| seg.start_with?(":") ? ":" : seg }.join("/")
      @segs = []
      @names = []
      text.split("/").each do |seg|
        next if seg.empty?
        if seg.start_with?(":")
          raise ArgumentError, "param without a name in #{text.inspect}" if seg.size == 1
          @segs << ""
          @names << seg[1, seg.size - 1]
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
        unless @names[i].empty?
          value = Params.unescape(path[pos, stop - pos])
          raise BadRequest, "a . or .. segment" if value == "." || value == ".."
          req.add_param(@names[i], value)
        end
        pos = stop + 1
        i += 1
      end
      nil
    end
  end

  class Route
    attr_reader :verb, :handler, :steps

    def initialize(verb, handler, scope)
      @verb = verb
      @handler = handler
      @scope = scope
      @own = []
      @steps = []
    end

    def attach(step)
      @own << step
      nil
    end

    # The layers of every enclosing scope, outermost first, then its own.
    def seal
      @scope.collect(@steps)
      @own.each { |step| @steps << step }
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
      raise ArgumentError, "#{route.verb} #{@pattern.text} is already routed" if @routes.any? { |r| r.verb == route.verb }
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

  # A path prefix with its layers. The router is the scope of "/"; each
  # #namespace opens one inside, whose routes run the layers of every
  # enclosing scope first.
  class Scope
    attr_reader :prefix, :chain

    def initialize(router, prefix, parent)
      @router = router
      @prefix = prefix
      @parent = parent
      @steps = []
      @chain = []
    end

    # A layer for every route in this scope, and for its 404 and 405.
    def use(layer)
      raise ArgumentError, "layers are fixed once the server starts" if @router.ready?
      @steps << Step.new(layer)
      nil
    end

    def get(path, handler, use: []) = @router.add_route("GET", self, path.to_s, handler, use)
    def post(path, handler, use: []) = @router.add_route("POST", self, path.to_s, handler, use)
    def put(path, handler, use: []) = @router.add_route("PUT", self, path.to_s, handler, use)
    def patch(path, handler, use: []) = @router.add_route("PATCH", self, path.to_s, handler, use)
    def delete(path, handler, use: []) = @router.add_route("DELETE", self, path.to_s, handler, use)

    # Yields the scope of path inside this one ("/" in it is path itself).
    # (Paths go through to_s: a verb the app never calls would otherwise
    # leave them untyped and widen the String code of the request path.)
    def namespace(path, use: [])
      scope = @router.add_scope(self, path.to_s)
      use.each { |layer| scope.use(layer) }
      yield scope
      nil
    end

    def join(path)
      raise ArgumentError, "path must start with /: #{path.inspect}" unless path.start_with?("/")
      return path if @prefix.empty?
      path == "/" ? @prefix : @prefix + path
    end

    def collect(list)
      @parent&.collect(list)
      @steps.each { |step| list << step }
      nil
    end

    def seal
      collect(@chain)
      nil
    end
  end

  # The routes with :params, as a radix tree: each node holds a run of
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

    # Adds a pattern ("/posts/:id/comments") ending in `value`.
    def add(text, value)
      node = self
      pos = 0
      while pos < text.bytesize
        open = text.index("/:", pos)
        open = open.nil? ? text.bytesize : open + 1
        node = node.insert(text.byteslice(pos, open - pos)) if open > pos
        break if open == text.bytesize
        node = node.param_node
        pos = text.index("/", open) || text.bytesize
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

  #   routes = HTTP::Router.new
  #   routes.use AccessLog.new
  #   routes.get "/posts/:id", ShowPost.new
  #   routes.namespace "/admin", use: [RequireToken.new] do |admin|
  #     admin.get "/", Dashboard.new
  #   end
  #
  # A layer is any object with `before(req, res)`, `after(req, res)` or
  # both. Befores run in order (outer scopes first, a route's own `use:`
  # last). One stops the chain by raising HTTP::Error (its status becomes
  # the response) or by answering with res.halt(status). Afters run in
  # reverse, once the response is final, for every layer whose before ran
  # (or that has none) up to where the chain stopped; res.error tells why
  # it failed.
  class Router
    def initialize
      @root = Scope.new(self, "", nil)
      @scopes = [@root]
      @groups = []
      @routes = []
      @exact = { "" => PathGroup.new(Pattern.new("")) }
      @exact.clear
      @tree = Radix.new("")
      @param_groups = []
      @ready = false
    end

    def use(layer) = @root.use(layer)
    def get(path, handler, use: []) = @root.get(path, handler, use: use)
    def post(path, handler, use: []) = @root.post(path, handler, use: use)
    def put(path, handler, use: []) = @root.put(path, handler, use: use)
    def patch(path, handler, use: []) = @root.patch(path, handler, use: use)
    def delete(path, handler, use: []) = @root.delete(path, handler, use: use)

    def namespace(path, use: [])
      @root.namespace(path, use: use) { |scope| yield scope }
    end

    def ready? = @ready

    def add_route(verb, scope, path, handler, layers)
      raise ArgumentError, "routes are fixed once the server starts" if @ready
      text = scope.join(path)
      group = @groups.find { |g| g.pattern.text == text }
      if group.nil?
        pattern = Pattern.new(text)
        other = @groups.find { |g| g.pattern.params? && g.pattern.shape == pattern.shape }
        raise ArgumentError, "#{text} matches the same paths as #{other.pattern.text}: name its params the same" if other
        group = PathGroup.new(pattern)
        @groups << group
      end
      route = Route.new(verb, handler, scope)
      layers.each { |layer| route.attach(Step.new(layer)) }
      group.add(route)
      @routes << route
      nil
    end

    def add_scope(parent, path)
      prefix = parent.join(path)
      raise ArgumentError, "namespace \"/\" is the router itself: use its #use" if prefix == "/"
      raise ArgumentError, "namespace #{prefix.inspect} ends in /" if prefix.end_with?("/")
      raise ArgumentError, "namespace #{prefix.inspect} is already open" if @scopes.any? { |s| s.prefix == prefix }
      scope = Scope.new(self, prefix, parent)
      @scopes << scope
      scope
    end

    # Resolves layers, Allow and lookup once; the server calls it before
    # the first request.
    def prepare
      return nil if @ready
      @scopes.each(&:seal)
      @routes.each(&:seal)
      @groups.each do |group|
        group.seal
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
      raise BadRequest, "a . or .. segment" if dot_segment?(path)
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
      run(scope_for(path).chain, req, res) do
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

    # "/api" covers "/api" and "/api/...", not "/apix"; "" covers all; a
    # :param segment of the prefix covers any non-empty segment.
    def self.covers?(prefix, path)
      i = 0
      j = 0
      while i < prefix.bytesize
        if prefix.getbyte(i) == 58 && prefix.getbyte(i - 1) == 47
          i += 1 while i < prefix.bytesize && prefix.getbyte(i) != 47
          from = j
          j += 1 while j < path.bytesize && path.getbyte(j) != 47
          return false if j == from
        else
          return false unless j < path.bytesize && path.getbyte(j) == prefix.getbyte(i)
          i += 1
          j += 1
        end
      end
      j == path.bytesize || path.getbyte(j) == 47
    end

    private

    # Whether a segment of the path is "." or "..".
    def dot_segment?(path)
      i = path.index("/.")
      while i
        stop = path.index("/", i + 1) || path.bytesize
        return true if stop == i + 2 || (stop == i + 3 && path.getbyte(i + 2) == 46)
        i = path.index("/.", i + 1)
      end
      false
    end

    # The deepest scope covering a path.
    def scope_for(path)
      found = @root
      @scopes.each do |scope|
        found = scope if scope.prefix.size > found.prefix.size && Router.covers?(scope.prefix, path)
      end
      found
    end

    # Befores in order until one halts, then the block; an error becomes
    # the response first, so the afters (in reverse, of every layer whose
    # before ran) see the final status and can still set headers.
    def run(steps, req, res)
      opened = 0
      begin
        while opened < steps.size
          step = steps[opened]
          step.layer.before(req, res) if step.opens
          opened += 1
          break if res.halted?
        end
        yield unless res.halted?
      rescue HTTP::Error => e
        res.error = e
        res.fail(e.status, e.message)
      rescue StandardError => e
        res.error = e
        warn "#{e.class}: #{e.message}"
        res.fail(500, "internal server error")
      ensure
        i = opened - 1
        while i >= 0
          step = steps[i]
          close(step.layer, req, res) if step.closes
          i -= 1
        end
      end
      nil
    end

    # One after; if it raises, the response becomes the error (when it can
    # still change) and the afters further out run all the same.
    def close(layer, req, res)
      layer.after(req, res)
      nil
    rescue StandardError => e
      warn "#{e.class}: #{e.message}"
      res.error = e if res.error.nil?
      res.fail(500, "internal server error") unless res.sent?
      nil
    end
  end
end
