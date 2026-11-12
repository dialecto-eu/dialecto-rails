require "psych"
require_relative "../scan/catalogs"

module DialectoRails
  module InContext
    # `(locale, key) → domain`, answered from the project's own locale files without running any code. A
    # string whose key isn't here is not marked: that leaves out every gem's locale files, `default:` text and
    # missing translations, none of which Dialecto holds.
    #
    # The domain is the file's path relative to `config/locales/` (spec-0015 §1), the server's bucket. Files
    # are read as a YAML syntax tree (`Psych.parse`, never `load`), so tags and aliases can't execute or expand;
    # a key reached only through a `<<: *alias` merge isn't indexed (the server locks those too).
    class KeyIndex
      RECHECK_MS = 500
      LOCALES_DIR = "config/locales/".freeze

      def initialize(root:, catalog_paths:, load_path: -> { ::I18n.load_path },
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) })
        @root = real(File.expand_path(root)).chomp("/") + "/"
        @catalogs = Scan::Catalogs.new(catalog_paths)
        @load_path = load_path
        @clock = clock
        @mutex = Mutex.new
        @signature = nil
        @checked_at = nil
        @table = {}
      end

      # The domain of `key` in `locale`, or nil.
      def domain(locale, key)
        refresh
        @table.dig(locale.to_s, key)
      end

      def locales
        refresh
        @table.keys
      end

      # Catalog files inside the project, in load order (later ones win a duplicate key).
      def files
        @load_path.call.filter_map do |path|
          full = real(File.expand_path(path.to_s))
          next unless full.start_with?(@root) && full.end_with?(".yml", ".yaml")

          relative = full.delete_prefix(@root)
          relative if @catalogs.match?(relative)
        end.uniq
      end

      def self.domain_for(relative_path)
        at = relative_path.start_with?(LOCALES_DIR) ? 0 : relative_path.index("/" + LOCALES_DIR)
        return relative_path unless at

        relative_path[(at.zero? ? LOCALES_DIR.length : at + 1 + LOCALES_DIR.length)..]
      end

      private

      # Symlinks resolved on both sides, so a project reached through one (macOS /var, a linked checkout) still
      # matches the paths Rails puts on the load path.
      def real(path)
        File.realpath(path)
      rescue SystemCallError
        path
      end

      def refresh
        now = @clock.call
        return if @checked_at && now - @checked_at < RECHECK_MS

        @mutex.synchronize do
          @checked_at = now
          paths = files
          signature = paths.map { |path| [path, mtime(path)] }
          next if signature == @signature

          @signature = signature
          @table = build(paths)
        end
      end

      def mtime(path)
        File.mtime(File.join(@root, path)).to_f
      rescue SystemCallError
        nil
      end

      def build(paths)
        table = Hash.new { |hash, locale| hash[locale] = {} }
        paths.each do |path|
          document = parse(File.join(@root, path))
          root = document&.root
          next unless root.is_a?(Psych::Nodes::Mapping)

          domain = self.class.domain_for(path)
          pairs(root).each do |locale_node, value|
            next unless locale_node.is_a?(Psych::Nodes::Scalar)

            walk(value, [], table[locale_node.value], domain)
          end
        end
        table.default_proc = nil
        table
      end

      def parse(path)
        Psych.parse_file(path)
      rescue Psych::SyntaxError, SystemCallError, EncodingError
        nil
      end

      def pairs(mapping) = mapping.children.each_slice(2).to_a

      def walk(node, path, table, domain)
        return unless node.is_a?(Psych::Nodes::Mapping)

        pairs(node).each do |key_node, value|
          next unless key_node.is_a?(Psych::Nodes::Scalar) && key_node.value != "<<"

          key_path = path + [key_node.value]
          table[key_path.join(".")] = domain
          walk(value, key_path, table, domain)
        end
      end
    end
  end
end
