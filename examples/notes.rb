# A small notes service: anyone reads a note, a client with the token
# writes one. Routes with a :param, a form field, errors, a layer, the
# access log.
#
#   curl -H "authorization: Bearer secret" -d "text=buy milk" localhost:8080/notes   # /notes/1
#   curl localhost:8080/notes/1                                                      # buy milk
require_relative "../spinel_http/server"

# Requests run on their own threads, so the store keeps its notes behind a lock.
class NoteStore
  def initialize
    @lock = Mutex.new
    @items = {}
    @last_id = 0
  end

  def add(text)
    @lock.synchronize do
      @last_id += 1
      @items[@last_id.to_s] = text
      @last_id.to_s
    end
  end

  def find(id)
    @lock.synchronize { @items[id] }
  end
end

class ShowNote
  def initialize(store)
    @store = store
  end

  def call(req, res)
    text = @store.find(req.param("id"))
    raise SpinelHTTP::NotFound, "no note #{req.param("id")}" if text.nil?
    res.text "#{text}\n"
  end
end

class CreateNote
  def initialize(store)
    @store = store
  end

  def call(req, res)
    text = req.form_params["text"]
    raise SpinelHTTP::BadRequest, "text is empty" if text.empty?
    res.status = 201
    res.text "/notes/#{@store.add(text)}\n"
  end
end

class RequireToken
  def before(req, res)
    raise SpinelHTTP::Unauthorized unless req.header("authorization") == "Bearer secret"
  end
end

store = NoteStore.new
routes = SpinelHTTP::Router.new
routes.get "/notes/:id", ShowNote.new(store)
routes.post "/notes", CreateNote.new(store), use: [RequireToken.new]

SpinelHTTP::Server.new(routes, port: ENV.fetch("PORT", "8080").to_i, observer: SpinelHTTP::AccessLog.new).listen
