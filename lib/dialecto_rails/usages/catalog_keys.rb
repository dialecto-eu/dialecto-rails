require "psych"
require "set"

module DialectoRails
  module Usages
    # The keys the project's catalogs hold, as Dialecto counts them: every leaf, and a plural's root as one key.
    # Read as a YAML syntax tree (never loaded), so tags and aliases can't run or expand.
    class CatalogKeys
      PLURAL_FORMS = %w[zero one two few many other].freeze

      def initialize
        @keys = Set.new
        @prefixes = Set.new
      end

      attr_reader :keys

      def add(content)
        document = Psych.parse(content)
        root = document&.root
        return self unless root.is_a?(Psych::Nodes::Mapping)

        pairs(root).each { |_locale, value| walk(value, []) }
        self
      rescue Psych::SyntaxError, EncodingError
        self
      end

      def include?(key) = @keys.include?(key)

      # True when `text` ends in a dot and some key starts with it (`"map."` in a prop).
      def prefix?(text)
        return false unless text.end_with?(".")

        @prefixes.include?(text)
      end

      def empty? = @keys.empty?

      private

      def pairs(mapping) = mapping.children.each_slice(2).to_a

      def walk(node, path)
        case node
        when Psych::Nodes::Mapping
          entries = pairs(node).select { |key, _value| key.is_a?(Psych::Nodes::Scalar) && key.value != "<<" }
          if !path.empty? && plural?(entries)
            add_key(path)
          else
            entries.each { |key, value| walk(value, path + [key.value]) }
          end
        when Psych::Nodes::Scalar, Psych::Nodes::Sequence then add_key(path) unless path.empty?
        end
      end

      def plural?(entries)
        entries.any? && entries.all? { |key, value| PLURAL_FORMS.include?(key.value) && !value.is_a?(Psych::Nodes::Mapping) }
      end

      def add_key(path)
        @keys << path.join(".")
        path[0...-1].each_index { |index| @prefixes << (path[0..index].join(".") + ".") }
      end
    end
  end
end
