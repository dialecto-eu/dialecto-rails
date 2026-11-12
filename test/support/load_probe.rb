$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "dialecto-rails"

loaded = {
  prism: defined?(::Prism) ? true : false,
  herb: defined?(::Herb) ? true : false,
  scan: DialectoRails.const_defined?(:Scan, false)
}
puts loaded.map { |name, value| "#{name}=#{value}" }.join(" ")
