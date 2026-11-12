module DialectoRails
  module Usages
    # Translate wrappers that come from a gem (an app that depends on spree never has `Spree.t`'s definition in its
    # tree), switched on by the gems in `Gemfile.lock` (spec-0023 §6.3). A project adds its own with the `wrappers`
    # setting; a declared wrapper takes the key as its first argument and puts `scope` in front of it.
    module KnownWrappers
      SPREE = [{call: "Spree.t", scope: "spree"}, {call: "Spree.translate", scope: "spree"}].freeze

      BY_GEM = {
        "spree_core" => SPREE,
        "solidus_core" => SPREE
      }.freeze

      # The declared entries as the scan uses them (`receiver:`, `name:`, `scope:`), from the project's `wrappers`
      # setting and the table for the locked gems. An entry that isn't `Const.method` is dropped.
      def self.declared(configured, gem_names)
        entries = Array(configured) + gem_names.flat_map { |name| BY_GEM.fetch(name, []) }
        entries.filter_map { |entry| parse(entry) }.uniq
      end

      def self.parse(entry)
        entry = entry.to_h.transform_keys(&:to_sym)
        match = entry[:call].to_s.strip.match(/\A(?:::)?((?:[A-Z]\w*::)*[A-Z]\w*)\.([a-z_]\w*[?!]?)\z/)
        return nil unless match

        scope = Array(entry[:scope]).map(&:to_s).reject(&:empty?).join(".")
        {receiver: match[1], name: match[2], scope: scope.empty? ? nil : scope}
      end
    end
  end
end
