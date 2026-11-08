# A :param arrives with its %XX escapes decoded ("+" stays a plus), and a
# path with a "." or ".." segment, written or escaped, is a 400 before any
# route sees it.
require "spinel_http/testing"

class ShowName
  def call(req, res) = res.text("[#{req.param("name")}]\n")
end

routes = SpinelHTTP::Router.new
routes.get "/files/:name", ShowName.new

[
  "GET /files/report.txt",
  "GET /files/a%2Fb",
  "GET /files/caf%C3%A9",
  "GET /files/a+b",
  "GET /files/%zz",
  "GET /files/..",
  "GET /files/%2e%2e",
  "GET /files/./x",
  "GET /files/../files/x",
  "GET /files/.hidden",
].each do |line|
  res = SpinelHTTP::Testing.request(routes, line)
  puts "#{line} -> #{res.status} #{res.body.chomp}"
end
