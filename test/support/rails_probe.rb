# Boots a small Rails app in the environment RAILS_ENV names, with the gem in the bundle, drives a few
# requests through it and prints one JSON line of facts. The in-context tests run it in a child process,
# because a Rails app can boot only once per process and the production guard is about what a booted
# production process holds.
#
#   RAILS_ENV=development DIALECTO_PROBE_ROOT=/tmp/app ruby rails_probe.rb
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "json"
require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "rack/mock"
require "dialecto_rails"


class ProbePagesController < ActionController::Base
  layout false

  TEMPLATE = <<~ERB
    <html><head><title>probe</title></head><body>
    <p id="hello"><%= t("hello") %></p>
    <p id="greet"><%= t("greet", name: "Ana") %></p>
    <p id="scoped"><%= t("title", scope: "pages.home") %></p>
    <p id="plural"><%= t("inbox.messages", count: params[:n].to_i) %></p>
    <p id="html"><%= t("banner_html") %></p>
    <p id="fallback"><%= t("only_english") %></p>
    <p id="default"><%= t("nope.nothing", default: "Fallback text") %></p>
    <p id="date"><%= t("date.formats.default") %></p>
    </body></html>
  ERB

  def index
    I18n.with_locale(params[:locale] || :en) { render inline: TEMPLATE }
  end

  def raw
    render html: "<p>no head</p>".html_safe
  end
end

class ProbeApp < Rails::Application
  config.root = ENV.fetch("DIALECTO_PROBE_ROOT")
  config.eager_load = false
  config.secret_key_base = "probe"
  config.logger = Logger.new(File::NULL)
  config.hosts.clear
  config.i18n.available_locales = %i[en es]
  config.i18n.fallbacks = true
  config.action_controller.perform_caching = false
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src :self
    policy.connect_src :self
  end
  config.content_security_policy_nonce_generator = ->(_request) { "n0nce" }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.dialecto.url = "http://localhost:4500"
  config.dialecto.project = "12"
  config.dialecto.skip_keys = ["pages.*"] if ENV["DIALECTO_PROBE_SKIP"]
  config.dialecto.enabled = false if ENV["DIALECTO_PROBE_DISABLED"]
  routes.append do
    root "probe_pages#index"
    get "raw", to: "probe_pages#raw"
  end
end

ProbeApp.initialize!

app = ProbeApp
base = {"HTTP_HOST" => "localhost:3000", "REMOTE_ADDR" => "127.0.0.1"}

def run(app, method, path, env, body = nil)
  options = env.merge(method: method)
  options[:input] = body if body
  status, headers, response = app.call(Rack::MockRequest.env_for(path, options))
  text = +""
  response.each { |part| text << part.to_s }
  {"status" => status, "headers" => headers, "body" => text.force_encoding(Encoding::UTF_8)}
rescue => error
  {"status" => nil, "raised" => error.class.name}
end

json = {"CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "http://localhost:3000"}
overrides = JSON.generate(edits: [
  {domain: "en.yml", key: "hello", locale: "en", to: "Howdy"},
  {domain: "en.yml", key: "banner_html", locale: "en", to: "<script>alert(1)</script><b>ok</b>"},
  {domain: "en.yml", key: "inbox.messages", locale: "en", forms: ["%{count} draft message", "%{count} draft messages"]}
])

facts = {}
facts["off"] = run(app, "GET", "/", base)
facts["marking"] = run(app, "POST", "/__dialecto/marking", base.merge(json), JSON.generate(on: true))
facts["on"] = run(app, "GET", "/", base)
facts["spanish"] = run(app, "GET", "/?locale=es", base)
facts["one"] = run(app, "GET", "/?n=1", base)
facts["raw"] = run(app, "GET", "/raw", base)
facts["context"] = run(app, "GET", "/__dialecto/context", base)
facts["lan"] = run(app, "GET", "/__dialecto/context", base.merge("REMOTE_ADDR" => "192.168.1.20"))
facts["lan_marking"] = run(app, "POST", "/__dialecto/marking", base.merge(json).merge("REMOTE_ADDR" => "192.168.1.20"),
  JSON.generate(on: true))
facts["overrides"] = run(app, "POST", "/__dialecto/overrides", base.merge(json), overrides)
facts["drafted"] = run(app, "GET", "/?n=3", base)
facts["stack"] = app.middleware.map { |middleware| middleware.klass.to_s }
facts["hooked"] = I18n::Backend::Simple.ancestors.map(&:to_s).grep(/Dialecto/)
facts["routes"] = app.routes.routes.map { |route| route.path.spec.to_s }.grep(/dialecto/i)
facts["constants"] = ObjectSpace.each_object(Module).filter_map(&:name).grep(/\ADialectoRails::InContext/).uniq.sort
facts["csp"] = app.config.content_security_policy&.build.to_s
puts "PROBE:" + JSON.generate(facts)
