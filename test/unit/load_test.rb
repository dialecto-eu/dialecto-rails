require "test_helper"
require "open3"
require "rbconfig"

class LoadTest < Minitest::Test
  # Bundler.require loads the gem's entry file in whatever group the Gemfile put it in. It must not pull in
  # the native parsers, or the scan code, outside the CLI.
  def test_the_entry_file_loads_no_parser_and_no_scanner
    probe = File.expand_path("../support/load_probe.rb", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, probe)

    assert status.success?, err
    assert_equal "prism=false herb=false scan=false", out.strip
  end
end
