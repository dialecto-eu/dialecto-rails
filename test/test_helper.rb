$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "stringio"
require "dialecto_rails"
require "dialecto_rails/scan/cli"

require_relative "support/fake_dialecto"
require_relative "support/git_fixture"

TOKEN = "dlk_" + ("a" * 43)
