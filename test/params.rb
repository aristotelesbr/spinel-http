# Query strings and urlencoded bodies: "+" and %XX decoded, repeated names,
# fields without "=", empty fields skipped, int with its default and its
# 400s, bad escapes and too many fields refused, reuse by parse; through
# the server, req.query_params and req.form_params (the form only for its
# content type), both reset between requests of one connection.
require "http/testing"

def refused
  yield
  puts "accepted"
rescue HTTP::Error => e
  puts "refused #{e.status}: #{e.message}"
end

p1 = HTTP::Params.new("q=two+words&tag=a&tag=b&empty=&flag&&x=%C3%A7%41&nome=S%C3%A3o+Paulo&raw=São")
p1.each { |k, v| puts "#{k.inspect} => #{v.inspect}" }
puts "size=#{p1.size} q=#{p1["q"]} missing=#{p1["missing"].inspect} flag?=#{p1.key?("flag")} nope?=#{p1.key?("nope")}"
puts "tags=#{p1.all("tag").inspect} none=#{p1.all("nope").inspect}"

p2 = HTTP::Params.new("page=12&neg=-5&blank=&word=abc&long=#{"9" * 19}&dash=-&max=#{"9" * 18}")
puts "page=#{p2.int("page", 1)} neg=#{p2.int("neg", 0)} absent=#{p2.int("absent", 7)} blank=#{p2.int("blank", 3)} max=#{p2.int("max", 0)}"
refused { p2.int("word", 0) }
refused { p2.int("long", 0) }
refused { p2.int("dash", 0) }

refused { HTTP::Params.new("a=%zz") }
refused { HTTP::Params.new("a=%4") }
refused { HTTP::Params.new("a=%") }
refused { HTTP::Params.new("%g1=x") }
refused { HTTP::Params.new("a&b&c&d", max_fields: 3) }
refused { HTTP::Params.new("a&b&c", max_fields: 3) }
puts HTTP::Params.new("").empty?

p1.parse("b=2")
puts "after parse: size=#{p1.size} q=#{p1["q"].inspect} b=#{p1["b"]}"

class Search
  def call(req, res)
    q = req.query_params
    res.text "q=#{q["q"]} page=#{q.int("page", 1)} tags=#{q.all("tag").join(",")}\n"
  end
end

class Signup
  def call(req, res)
    f = req.form_params
    res.text "name=#{f["name"]} age=#{f.int("age", 0)} fields=#{f.size} from=#{req.query_params["from"]}\n"
  end
end

routes = HTTP::Router.new
routes.get "/search", Search.new
routes.post "/signup", Signup.new

def show(r) = puts("#{r.status} #{r.body.strip}")

form = "application/x-www-form-urlencoded"
show HTTP::Testing.request(routes, "GET /search?q=ruby+spinel&page=2&tag=a&tag=b")
show HTTP::Testing.request(routes, "GET /search")
show HTTP::Testing.request(routes, "GET /search?page=abc")
show HTTP::Testing.request(routes, "GET /search?q=%zz")
show HTTP::Testing.request(routes, "GET /search?#{"a&" * 1001}")
show HTTP::Testing.request(routes, "POST /signup?from=ad", headers: { "content-type" => form }, body: "name=Ana+Maria&age=30")
show HTTP::Testing.request(routes, "POST /signup", headers: { "content-type" => "Application/X-WWW-Form-Urlencoded; charset=UTF-8" }, body: "name=Bo")
show HTTP::Testing.request(routes, "POST /signup", headers: { "content-type" => "application/json" }, body: "name=Eve")
show HTTP::Testing.request(routes, "POST /signup", headers: { "content-type" => form }, body: "age=old")

# Two requests on one connection: the second sees its own fields only.
two = "GET /search?q=first&tag=x HTTP/1.1\r\nhost: t\r\n\r\n" \
      "GET /search HTTP/1.1\r\nhost: t\r\nconnection: close\r\n\r\n"
HTTP::Testing.raw(routes, two).gsub("\r\n", "\n").split("\n").each { |l| puts l if l.start_with?("q=") }
