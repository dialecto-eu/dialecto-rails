# The settings a project in the corpus would give the scan: monorepos keep catalogs in every engine's
# config/locales, and two apps declare `Spree.t` (spree has no lockfile of its own, and openfoodnetwork carries its
# own copy whose scope comes from `unshift(:spree)`, which the scan can't read).
require "dialecto_rails"

SPREE_WRAPPERS = [{call: "Spree.t", scope: "spree"}, {call: "Spree.translate", scope: "spree"}].freeze
DECLARED = {"spree" => SPREE_WRAPPERS, "openfoodnetwork" => SPREE_WRAPPERS}.freeze

def corpus_config(dir)
  DialectoRails::Config.new({catalog_paths: ["**/config/locales/**/*.yml", "**/config/locales/**/*.yaml"],
                             wrappers: DECLARED.fetch(File.basename(dir), [])}, {})
end
