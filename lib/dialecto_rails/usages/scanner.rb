require "prism"
require_relative "../version"
require_relative "../scan/catalogs"
require_relative "catalog_keys"
require_relative "ruby_visitor"
require_relative "wrappers"
require_relative "known_wrappers"
require_relative "templates"

module DialectoRails
  module Usages
    # The usage scan (spec-0023 §6): every place the code at one commit reads a translation key, in the shape
    # spec-0022 §6 fixes (the `railsUsages` object). Reads committed blobs through `Scan::Git`, never the
    # working tree.
    class Scanner
      VERSION = "1.0.0".freeze
      MAX_BYTES = 1_000_000
      MAX_NAMED_KEYS = 200
      DEFAULT_EXCLUDES = %w[node_modules vendor tmp log coverage public/assets app/assets/builds].freeze
      EXCLUDED_PREFIXES = %w[public/packs].freeze
      # What a generator copies into a new app is text for another app: it holds ERB inside `.rb` and is never loaded.
      GENERATOR_TEMPLATES = %r{(?:\A|/)lib/generators/(?:.+/)?templates/}
      RUBY_EXTENSIONS = %w[.rb .rake .jbuilder .builder .arb].freeze
      SCRIPT_EXTENSIONS = %w[.js .jsx .ts .tsx .mjs .cjs .coffee].freeze
      I18N_JS_CONFIGS = %w[config/i18n.yml config/i18n-js.yml config/i18n.js].freeze
      JS_STRING = /"((?:[^"\\\n]|\\.){1,200})"|'((?:[^'\\\n]|\\.){1,200})'|`([^`$\\\n]{1,200})`/

      Source = Struct.new(:path, :lang, :bytes, keyword_init: true)

      # The catalog keys read at the scanned commit, available after `call`.
      attr_reader :catalog

      def initialize(git:, sha:, config:)
        @git = git
        @sha = sha
        @config = config
        @unscanned = []
        @catalog = CatalogKeys.new
      end

      def call
        entries = @git.entries(@sha).reject { |entry| excluded?(entry.path) }
        contents = {}
        read = ->(entry) { contents[entry.path] ||= @git.blob(entry.blob) }
        catalog_entries = entries.select { |entry| catalogs.match?(entry.path) }
        catalog_entries.each { |entry| @catalog.add(read.call(entry)) }

        sources = []
        entries.each do |entry|
          next if catalogs.match?(entry.path)

          classify(entry, sources, read)
        end
        contents.clear

        locked_gems = gems(entries, read)
        declared = KnownWrappers.declared(@config.wrappers, locked_gems.map { |gem| gem["name"] })
        wrappers = Wrappers.new(i18n_functions: @config.i18n_functions, declared: declared)
        programs = {}
        sources.each do |source|
          program = parse(source)
          next unless program

          programs[source.path] = [source, program]
          guarded(source) { wrappers.scout(source.path, program) unless RubyVisitor::TEST_FILE.match?(source.path) }
        end
        wrappers.resolve!

        usages = []
        conventions = []
        programs.each do |path, (source, program)|
          guarded(source) do
            result = RubyVisitor.new(file: path, lang: source.lang.to_s, bytes: source.bytes, wrappers: wrappers,
              catalog: @catalog, i18n_functions: @config.i18n_functions).call(program)
            usages.concat(result.records)
            conventions.concat(result.conventions)
          end
        end

        {
          "version" => VERSION,
          "parsers" => parsers,
          "gems" => locked_gems,
          "usages" => order(resolve_overlaps(usages)),
          "unscanned" => @unscanned.sort_by { |item| [item["file"], item["reason"]] },
          "conventions" => conventions.sort_by { |item| [item["file"], item["line"], item["key"].to_s] }
        }
      end

      private

      def catalogs = @catalogs ||= Scan::Catalogs.new(@config.catalog_paths)

      def custom_excludes = @custom_excludes ||= Scan::Catalogs.new(@config.usages_exclude)

      def excluded?(path)
        return true if DEFAULT_EXCLUDES.any? { |name| path == name || path.start_with?("#{name}/") || path.include?("/#{name}/") }
        return true if EXCLUDED_PREFIXES.any? { |prefix| path.start_with?(prefix) }
        return true if GENERATOR_TEMPLATES.match?(path)

        !@config.usages_exclude.empty? && custom_excludes.match?(path)
      end

      def classify(entry, sources, read)
        path = entry.path
        extension = File.extname(path).downcase
        if path.end_with?(".slim")
          return unscanned(path, "Slim isn't scanned")
        elsif SCRIPT_EXTENSIONS.include?(extension)
          return script(entry, read)
        end

        lang = template_language(path, extension)
        return unless lang

        bytes = entry.size > MAX_BYTES ? nil : read.call(entry)
        return unscanned(path, "could not be parsed: file is larger than #{MAX_BYTES} bytes") unless bytes

        bytes = bytes.dup.force_encoding(Encoding::UTF_8)
        return unscanned(path, "could not be parsed: the file is not valid UTF-8") unless bytes.valid_encoding?

        sources << Source.new(path: path, lang: lang, bytes: bytes)
      end

      def template_language(path, extension)
        return :ruby if RUBY_EXTENSIONS.include?(extension) || %w[Rakefile Gemfile].include?(File.basename(path))
        return :erb if extension == ".erb"

        :haml if extension == ".haml"
      end

      def script(entry, read)
        return if entry.size > MAX_BYTES

        if i18n_js_configured?
          return unscanned(entry.path, "JavaScript that reads the locale files isn't scanned")
        end
        return if @catalog.empty?

        text = read.call(entry).dup.force_encoding(Encoding::UTF_8).scrub("")
        named = text.scan(JS_STRING).map { |groups| groups.compact.first.to_s }.select { |name| @catalog.include?(name) }.uniq.sort
        return if named.empty?

        # The keys the file names as strings stay locked server-side; the file itself is a place to check.
        # A list past the cap would silently unlock the rest, so it is sent as "all": the file locks every key.
        keys = named.size > MAX_NAMED_KEYS ? "all" : named
        unscanned(entry.path, "JavaScript that names a catalog key isn't scanned", keys: keys)
      end

      def i18n_js_configured?
        return @i18n_js unless @i18n_js.nil?

        paths = @git.entries(@sha).map(&:path)
        @i18n_js = I18N_JS_CONFIGS.any? { |name| paths.include?(name) }
      end

      def unscanned(path, reason, keys: nil)
        item = {"file" => path, "reason" => reason}
        item["keys"] = keys if keys
        @unscanned << item
      end

      def parse(source)
        ruby = case source.lang
        when :ruby then source.bytes
        when :erb then Templates.erb(source.bytes)
        when :haml then Templates.haml(source.bytes)
        end
        return haml_unavailable(source) if ruby.nil?

        result = Prism.parse(ruby, version: "latest")
        errors = source.lang == :ruby ? result.errors : result.errors.reject { |error| TEMPLATE_TOLERATED.include?(error.message) }
        unless errors.empty?
          unscanned(source.path, parse_reason(errors.first.message))
          return nil
        end
        result.value
      rescue Templates::Unreadable => e
        unscanned(source.path, parse_reason(e.message)) # our own message: a line number, never source text
        nil
      rescue => e
        # A parser's exception message may quote the source, so only its class leaves the machine.
        unscanned(source.path, parse_reason("#{e.class.name} while reading the template"))
        nil
      end

      REASON_LIMIT = 200

      # `could not be parsed: <message>`, the message cut to 200 bytes on a character boundary.
      def parse_reason(message)
        text = message.to_s.lines.first.to_s.strip.byteslice(0, REASON_LIMIT).to_s.dup.force_encoding(Encoding::UTF_8)
        text = text.byteslice(0, text.bytesize - 1).force_encoding(Encoding::UTF_8) until text.empty? || text.valid_encoding?
        "could not be parsed: #{text}"
      end

      # A template's Ruby isn't inside a method: a layout's `yield` is fine there.
      TEMPLATE_TOLERATED = ["Invalid yield", "Invalid return in class/module body"].freeze

      # A bug in the scan on one file must not take the others down; the file is reported, not hidden.
      def guarded(source)
        yield
      rescue => e
        unscanned(source.path, parse_reason("internal error (#{e.class.name})"))
      end

      def haml_unavailable(source)
        unscanned(source.path, "HAML isn't scanned")
        nil
      end

      def gems(entries, read)
        lock = entries.find { |entry| entry.path == "Gemfile.lock" }
        return [] unless lock

        specs = read.call(lock).dup.force_encoding(Encoding::UTF_8).scrub("").scan(/^ {4}(\S+) \(([^)\s]+)\)\s*$/)
        specs.map { |name, version| {"name" => name, "version" => version} }.uniq.sort_by { |gem| [gem["name"], gem["version"]] }
      end

      def parsers
        {"dialecto-rails" => VERSION_STRING, "prism" => Prism::VERSION, "herb" => Templates.herb_version,
         "haml" => Templates.haml_version}.compact
      end

      VERSION_STRING = DialectoRails::VERSION

      # A `literal` that lies inside a call record's anchor is already part of that use.
      def resolve_overlaps(usages)
        usages.group_by { |usage| usage["file"] }.flat_map do |_file, records|
          claims = records.reject { |record| record["kind"] == "literal" }.map { |record| claim(record) }
          records.reject do |record|
            record["kind"] == "literal" && claims.any? { |from, to| record["offset"] >= from && record["offset"] < to }
          end
        end
      end

      def claim(record) = [record["offset"], record["offset"] + record["content"].bytesize]

      def order(usages) = usages.sort_by { |usage| [usage["file"].b, usage["offset"]] }
    end
  end
end
