require "test_helper"

class ConfigTest < Minitest::Test
  def config(options = {}, env = {}) = DialectoRails::Config.new(options, env)

  def test_defaults
    c = config
    assert_equal "https://app.dialecto.eu", c.url
    assert_nil c.project
    assert_nil c.scan_token
    assert_equal ["config/locales/**/*.yml", "config/locales/**/*.yaml"], c.catalog_paths
    assert_equal "config/locales", c.catalogs
    assert_equal [], c.usages_exclude
    assert_equal [], c.i18n_functions
    assert_equal false, c.usages?
    assert_equal true, c.enabled?
  end

  def test_declared_wrappers_from_an_option_or_the_environment
    assert_equal [], config.wrappers
    assert_equal [{call: "Spree.t", scope: "spree"}], config({wrappers: [{call: "Spree.t", scope: "spree"}]}).wrappers
    assert_equal [{call: "Spree.t", scope: "spree"}, {call: "A::B.tr", scope: nil}],
      config({}, "DIALECTO_WRAPPERS" => "Spree.t=spree, A::B.tr").wrappers
  end

  def test_environment_over_default
    c = config({}, "DIALECTO_URL" => "http://127.0.0.1:4500/", "DIALECTO_PROJECT" => "12",
      "DIALECTO_CATALOG_PATHS" => "a/*.yml, b/**/*.yml", "DIALECTO_USAGES" => "on")
    assert_equal "http://127.0.0.1:4500", c.url
    assert_equal "12", c.project
    assert_equal ["a/*.yml", "b/**/*.yml"], c.catalog_paths
    assert c.usages?
  end

  def test_option_over_environment
    c = config({url: "https://dialecto.example", project: 7, catalog_paths: ["x/*.yml"], usages: false},
      "DIALECTO_URL" => "https://env.example", "DIALECTO_PROJECT" => "12", "DIALECTO_CATALOG_PATHS" => "y/*.yml",
      "DIALECTO_USAGES" => "on")
    assert_equal "https://dialecto.example", c.url
    assert_equal "7", c.project
    assert_equal ["x/*.yml"], c.catalog_paths
    assert_equal false, c.usages?
  end

  def test_blank_option_falls_through_to_environment
    c = config({url: "  ", catalog_paths: []}, "DIALECTO_URL" => "https://env.example", "DIALECTO_CATALOG_PATHS" => "y/*.yml")
    assert_equal "https://env.example", c.url
    assert_equal ["y/*.yml"], c.catalog_paths
  end

  def test_in_context_switch_values
    %w[off false 0 no OFF].each { |value| refute config({}, "DIALECTO_IN_CONTEXT" => value).enabled?, value }
    assert config({}, "DIALECTO_IN_CONTEXT" => "on").enabled?
    refute config({enabled: false}, "DIALECTO_IN_CONTEXT" => "on").enabled?
  end

  def test_token_comes_only_from_the_environment
    assert_nil config({scan_token: "dlk_option"}).scan_token
    assert_equal TOKEN, config({}, "DIALECTO_SCAN_TOKEN" => " #{TOKEN} ").scan_token
  end

  def test_url_rules_for_carrying_a_token
    assert_nil config({url: "https://app.dialecto.eu"}).url_problem
    assert_nil config({url: "http://localhost:4500"}).url_problem
    assert_nil config({url: "http://127.0.0.1:4500"}).url_problem
    assert_match(/plain http/, config({url: "http://dialecto.internal"}).url_problem)
    assert_nil config({url: "http://dialecto.internal"}, "DIALECTO_ALLOW_INSECURE" => "1").url_problem
    assert_match(/isn't an http/, config({url: "ftp://x"}).url_problem)
    assert_match(/isn't an http/, config({url: "not a url"}).url_problem)
  end
end
