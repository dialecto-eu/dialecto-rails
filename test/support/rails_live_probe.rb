# Boots a small production Rails app, with or without live-site editing configured, drives requests through
# it and prints one JSON line of facts. Run in a child process (a Rails app boots once per process), by
# test/integration/rails_live_test.rb:
#
#   RAILS_ENV=production DIALECTO_PROBE_ROOT=/tmp/app DIALECTO_PROBE_VECTORS=… [DIALECTO_PROBE_LIVE=1] ruby rails_live_probe.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "json"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "action_mailer/railtie"
require "rack/mock"
require "dialecto_rails"

$vectors = JSON.parse(File.read(ENV.fetch("DIALECTO_PROBE_VECTORS")))
vectors = $vectors
valid = vectors["cases"].find { |entry| entry["name"] == "valid" }
$now = valid["now"]

class ProbeMailer < ActionMailer::Base
  default from: "from@example.com", to: "to@example.com"

  def hello
    mail(subject: "Hello") { |format| format.text { render plain: I18n.t("hello") } }
  end
end

class ProbePagesController < ActionController::Base
  layout false

  TEMPLATE = <<~ERB
    <html><head><title>probe</title></head><body>
    <p id="hello"><%= t("hello") %></p>
    <p id="greet"><%= t("greet", name: "Ana") %></p>
    <p id="plural"><%= t("inbox.messages", count: 2) %></p>
    <p id="mail"><%= @mail %></p>
    <p id="mail_unwrapped"><%= @mail_unwrapped %></p>
    <% cache ["frag", params[:v]] do %><p id="cached"><%= t("hello") %></p><% end %>
    <p id="session"><%= session.loaded? ? "loaded" : "untouched" %></p>
    </body></html>
  ERB

  def index
    @mail = DialectoRails.unmarked { ProbeMailer.hello.deliver_now.body.to_s }
    @mail_unwrapped = ProbeMailer.hello.deliver_now.body.to_s
    render inline: TEMPLATE
  end

  def create
    render plain: I18n.t("hello")
  end

  def api
    render json: {hello: I18n.t("hello")}
  end
end

class ProbeApp < Rails::Application
  config.root = ENV.fetch("DIALECTO_PROBE_ROOT")
  config.eager_load = false
  config.secret_key_base = "probe"
  config.logger = Logger.new(File::NULL)
  config.hosts.clear
  config.i18n.available_locales = %i[en es]
  config.session_store :cookie_store, key: "_probe_session"
  config.action_controller.allow_forgery_protection = false
  config.action_controller.perform_caching = true
  config.cache_store = :memory_store
  config.action_mailer.delivery_method = :test
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
  end
  if ENV["DIALECTO_PROBE_LIVE"] == "1"
    config.dialecto.mode = :live
    config.dialecto.repo = "example/app"
    config.dialecto.origin = $vectors["origin"]
    config.dialecto.public_key = $vectors["public"]
    config.dialecto.clock = -> { $now }
  end
  routes.append do
    root "probe_pages#index"
    get "dash", to: "probe_pages#index"
    post "dash", to: "probe_pages#create"
    get "api", to: "probe_pages#api"
  end
end

ProbeApp.initialize!

def run(method, path, env = {}, body = nil)
  options = {method: method}.merge(env)
  options[:input] = body if body
  status, headers, response = ProbeApp.call(Rack::MockRequest.env_for(path, options))
  text = +""
  response.each { |part| text << part.to_s }
  {"status" => status, "headers" => headers.to_h, "body" => text.force_encoding(Encoding::UTF_8)}
rescue => error
  {"status" => nil, "raised" => "#{error.class}: #{error.message}"}
end

def jar(response, previous = {})
  Array(response["headers"]["set-cookie"]).flat_map { |value| value.split("\n") }.each_with_object(previous.dup) do |line, cookies|
    name, rest = line.split("=", 2)
    value = rest.to_s.split(";").first.to_s
    attributes = rest.to_s.downcase
    if value.empty? || attributes.include?("max-age=0")
      cookies.delete(name)
    else
      cookies[name] = value
    end
  end
end

def cookie_header(jar) = jar.map { |name, value| "#{name}=#{value}" }.join("; ")

document = {"HTTP_SEC_FETCH_DEST" => "document", "HTTP_ACCEPT" => "text/html,application/xhtml+xml"}
origin = {"HTTP_ORIGIN" => vectors["origin"]}

facts = {}
facts["visitor"] = run("GET", "/dash?x=1", document)
facts["visitor_json"] = run("GET", "/api", "HTTP_ACCEPT" => "application/json")
facts["start"] = run("GET", "/dash?x=1&dialecto_edit=#{valid["token"]}&y=2", document)
cookies = jar(facts["start"])
facts["cookies"] = cookies.keys
with_cookies = ->(extra = {}) { {"HTTP_COOKIE" => cookie_header(cookies)}.merge(extra) }
facts["editor"] = run("GET", "/dash?v=2", with_cookies.call(document))
facts["visitor_after"] = run("GET", "/dash?v=2", document)
facts["filter_parameters"] = ProbeApp.config.filter_parameters.map(&:to_s)
facts["post"] = run("POST", "/dash", with_cookies.call(origin))
facts["api"] = run("GET", "/api", with_cookies.call("HTTP_SEC_FETCH_DEST" => "empty", "HTTP_ACCEPT" => "application/json"))
facts["routes"] = %w[context overrides marking].to_h do |name|
  method = (name == "context") ? "GET" : "POST"
  [name, run(method, "/__dialecto/#{name}", {"HTTP_HOST" => "localhost:3000", "REMOTE_ADDR" => "127.0.0.1",
                                              "HTTP_ORIGIN" => "http://localhost:3000", "CONTENT_TYPE" => "application/json"}, JSON.generate(on: true))["status"]]
end
facts["stop"] = run("POST", "/__dialecto/stop", with_cookies.call(origin))
cookies = jar(facts["stop"], cookies)
facts["after_stop"] = run("GET", "/dash", with_cookies.call(document))
facts["stack"] = ProbeApp.middleware.map { |middleware| middleware.klass.to_s }
facts["hooked"] = I18n::Backend::Simple.ancestors.map(&:to_s).grep(/Dialecto/)
facts["constants"] = ObjectSpace.each_object(Module).filter_map(&:name).grep(/\ADialectoRails::InContext/).uniq.sort
puts "PROBE:" + JSON.generate(facts)
