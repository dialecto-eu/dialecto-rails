require_relative "dialecto_rails/version"
require_relative "dialecto_rails/unmarked"

# What Bundler.require loads: the version and, inside a Rails app, the Railtie stub. The scanner and the
# usage scan (and their native Prism and Herb) are required by the CLI only.
module DialectoRails
  autoload :Config, "dialecto_rails/config"
  autoload :Error, "dialecto_rails/errors"
  autoload :ConfigError, "dialecto_rails/errors"
  autoload :RefusedError, "dialecto_rails/errors"
  autoload :RetryableError, "dialecto_rails/errors"
end

require_relative "dialecto_rails/in_context/railtie_stub" if defined?(::Rails::Railtie)
