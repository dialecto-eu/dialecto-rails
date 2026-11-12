require_relative "lib/dialecto_rails/version"

Gem::Specification.new do |spec|
  spec.name = "dialecto-rails"
  spec.version = DialectoRails::VERSION
  spec.authors = ["Dialecto"]
  spec.summary = "Dialecto for Rails: scan locale files, find call sites, edit text in context."
  spec.description = "The Rails side of Dialecto's minimal-diff translation pull requests: a scanner " \
                     "that sends config/locales to Dialecto from CI, a static scan of where the code " \
                     "reads each key, and a development-only in-context editor."
  spec.homepage = "https://dialecto.eu"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "lib/dialecto_rails/in_context/assets/overlay.js", "lib/dialecto_rails/usages/read_by_name.json", "exe/*", "action.yml", "LICENSE", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["dialecto-rails"]
  spec.require_paths = ["lib"]

  # Prism is a default gem from Ruby 3.3; the version floor keeps 3.2 and old 3.3 installs honest.
  # Herb parses ERB. Both are native and are only loaded by the CLI's usage scan, never by Bundler.require.
  spec.add_dependency "prism", ">= 1.0"
  spec.add_dependency "herb"
end
