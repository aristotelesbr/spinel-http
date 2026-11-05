# Route lookup: an exact path wins over a pattern, a literal segment over
# a {param} at the same place (falling back to the param when the literal
# branch has no route), params nest, and "/" and trailing slashes match
# only what is registered.
require "http/testing"

class Name
  def initialize(name)
    @name = name
  end

  def call(req, res)
    res.text("#{@name} id=#{req.param("id")} cid=#{req.param("cid")} slug=#{req.param("slug")}\n")
  end
end

routes = HTTP::Router.new
routes.handle "GET /", Name.new("root")
routes.handle "GET /posts", Name.new("index")
routes.handle "GET /posts/new", Name.new("new")
routes.handle "GET /posts/new/preview", Name.new("preview")
routes.handle "GET /posts/{id}", Name.new("show")
routes.handle "GET /posts/{id}/edit", Name.new("edit")
routes.handle "GET /posts/{id}/comments/{cid}", Name.new("comment")
routes.handle "GET /pages/{slug}", Name.new("page")
routes.handle "GET /pages/about/team", Name.new("team")

["/", "/posts", "/posts/", "/posts/new", "/posts/new/preview", "/posts/new/edit",
 "/posts/7", "/posts/7/edit", "/posts/7/comments/3", "/posts/7/comments",
 "/posts/7/comments/3/x", "/pages/about", "/pages/about/team", "/pages/about/x",
 "/nope", "/postsx", "/posts//edit"].each do |path|
  r = HTTP::Testing.request(routes, "GET #{path}")
  puts "#{path} -> #{r.status} #{r.body}"
end
