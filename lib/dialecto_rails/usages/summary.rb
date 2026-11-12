require "json"

module DialectoRails
  module Usages
    # The developer's view of a usage scan (spec-0023 §6.7): uses by kind, every catalog key sorted by how a
    # rename could treat it, and what wasn't read. It follows the server's classification (dlocal
    # `Dlocal.Localize.KeyRename`, spec-0022 §5.6), which decides; a parity test holds the two together.
    #
    #   alone      read only by calls that name it
    #   family     a shared template or a group lookup reaches it: renamed only with its group
    #   locked     Rails or a gem reads it by name, a JavaScript file names it as a string, or a call whose
    #              key is partly known could reach it. A file the scan can't read and a lookup of a wholly
    #              unknown key lock nothing: they are places to check, listed at the end.
    #   unreached  nothing reads it
    class Summary
      # What Rails and the gems read by name; the server owns this file and the gem ships a copy.
      READ_BY_NAME = JSON.parse(File.read(File.join(__dir__, "read_by_name.json"))).freeze

      Row = Struct.new(:key, :klass, :because, :prefix, keyword_init: true)

      def initialize(envelope, catalog_keys)
        @envelope = envelope
        @keys = catalog_keys.sort
      end

      def kinds = @envelope["usages"].group_by { |usage| usage["kind"] }.transform_values(&:length).sort.to_h

      def rows
        @rows ||= begin
          index
          @keys.map { |key| classify(key) }
        end
      end

      def counts = rows.group_by(&:klass).transform_values(&:length)

      def render
        lines = ["Uses: #{kinds.map { |kind, count| "#{count} #{kind}" }.join(", ").then { |text| text.empty? ? "none" : text }}"]
        counts.then { |by| lines << "Catalog keys: " + %w[alone family locked unreached].map { |name| "#{by[name.to_sym] || 0} #{name}" }.join(", ") }
        rows.select { |row| row.klass == :locked }.each { |row| lines << "  #{row.key} can't be renamed: #{row.because}" }
        unreached = rows.select { |row| row.klass == :unreached }
        lines << "Nothing reads #{unreached.length} keys (first: #{unreached.first(3).map(&:key).join(", ")})." unless unreached.empty?
        @envelope["unscanned"].each { |item| lines << "Not scanned: #{item["file"]} (#{item["reason"]})" }
        unknown = @envelope["usages"].select { |usage| usage["kind"] == "pattern" && wholly_unknown?(usage) }
        unknown.each { |usage| lines << "Unknown key: #{usage["file"]}:#{usage["start_line"]} (#{reason_text(usage["reason"])})" }
        places = @envelope["unscanned"].length + unknown.length
        lines << "#{places} places Dialecto can't read; you check them before a rename." if places.positive?
        lines.join("\n")
      end

      private

      def index
        @index ||= begin
          usages = @envelope["usages"]
          static = {}
          set_by = Hash.new { |hash, key| hash[key] = [] }
          templates = {}
          patterns = []
          implicit = Hash.new { |hash, key| hash[key] = [] }
          usages.each do |usage|
            case usage["kind"]
            when "static" then static[usage["key"]] = true
            when "template" then templates[usage["id"]] = usage
            when "set" then usage["keys"].each { |key| set_by[key] << usage }
            when "pattern" then patterns << [usage, tokens(usage["parts"])] unless wholly_unknown?(usage)
            end
            Array(usage["defaults"]).each do |default|
              if default.key?("span") then static[default["key"]] = true
              else implicit[default["key"]] << usage
              end
            end
          end
          { static: static, set_by: set_by, templates: templates, patterns: patterns, implicit: implicit,
            rules: read_by_name_rules }
        end
      end

      # A lookup of a key nothing is known about (`t(key)`): a place to check, not a lock on every key.
      def wholly_unknown?(usage) = usage["parts"].none? { |part| part.key?("lit") }

      # Rails' namespaces, the prefixes of the scan's gems and the scan's own conventions.
      def read_by_name_rules
        namespaces = READ_BY_NAME["namespaces"].map { |entry| { prefix: entry["prefix"], reader: entry["reader"] } }
        gems = Array(@envelope["gems"]).flat_map do |gem|
          Array(READ_BY_NAME["gems"][gem["name"]]).map { |prefix| { prefix: prefix, reader: "the #{gem["name"]} gem reads this key by its name" } }
        end
        conventions = Array(@envelope["conventions"]).map do |entry|
          { prefix: entry["prefix"], key: entry["key"], reader: "the app reads this key by its name" }
        end
        namespaces + gems.uniq + conventions
      end

      def classify(key)
        because = lock_reason(key)
        return Row.new(key: key, klass: :locked, because: because) if because

        groups = group_starts(key)
        if index[:set_by].key?(key) || !groups.empty?
          family(key, groups)
        elsif index[:static][key] then Row.new(key: key, klass: :alone)
        else Row.new(key: key, klass: :unreached)
        end
      end

      def lock_reason(key)
        # A file the scan can't read is a place to check, not a lock; a key the file names as a string stays locked.
        unscanned = @envelope["unscanned"].find { |item| item["keys"] == "all" || Array(item["keys"]).include?(key) }
        return "#{unscanned["file"]} names it as a string (#{unscanned["reason"]})" if unscanned

        rule = index[:rules].find { |entry| entry[:prefix] ? key.start_with?(entry[:prefix]) : entry[:key] == key }
        return rule[:reader] if rule

        implicit = index[:implicit][key].first
        return "#{implicit["file"]}:#{implicit["start_line"]} reads it as a fallback Rails adds" if implicit

        hit = index[:patterns].find { |_usage, tokens| matches?(tokens, key) }
        return "#{hit.first["file"]}:#{hit.first["start_line"]} #{reason_text(hit.first["reason"])}" if hit
      end

      def family(key, groups)
        sets = index[:set_by][key]
        starts = sets.map { |set| start_of(set) } + groups
        prefix = starts.any?(&:nil?) ? "" : shared_prefix(starts)
        if prefix.empty?
          because = sets.map { |set| "#{set["file"]}:#{set["start_line"]} builds it from a template with no fixed dotted start" }.first
          Row.new(key: key, klass: :locked, because: because)
        else
          Row.new(key: key, klass: :family, because: prefix, prefix: prefix)
        end
      end

      def start_of(set)
        origin = set["via"] && index[:templates][set["via"].first]
        parts = set["via"] ? origin && origin["parts"] : set["parts"]
        first = parts&.first
        first && first["lit"]
      end

      # The longest dotted prefix every start shares ("" when they share no dot).
      def shared_prefix(starts)
        common = starts.reduce do |left, right|
          left[0, (0...[left.length, right.length].min).take_while { |at| left[at] == right[at] }.length]
        end
        segments = common.split(".", -1)
        segments.length < 2 ? "" : segments[0...-1].join(".") + "."
      end

      # `users.` for `users.index.title` when a call names the group `users`, which is no catalog key.
      def group_starts(key)
        @catalog ||= @keys.to_h { |catalog_key| [catalog_key, true] }
        positions = (0...key.length).select { |at| key[at] == "." && at.positive? }
        positions.filter_map do |at|
          group = key[0, at]
          "#{group}." if index[:static][group] && !@catalog[group]
        end
      end

      # A pattern is a glob: literals and `*`. A wildcard matches any text, empty included.
      def tokens(parts)
        parts.each_with_object([]) do |part, acc|
          if part["wild"] then acc << :wild unless acc.last == :wild
          elsif !part["lit"].to_s.empty?
            acc.last.is_a?(String) ? acc.last << part["lit"] : acc << part["lit"].dup
          end
        end
      end

      def matches?(tokens, key)
        regexp = Regexp.new("\\A" + tokens.map { |token| token == :wild ? ".*" : Regexp.escape(token) }.join + "\\z", Regexp::MULTILINE)
        regexp.match?(key)
      end

      def reason_text(reason)
        {
          "dynamic_scope" => "reads a key under a scope that isn't a literal",
          "lazy_action_unknown" => "reads a lazy key outside a known action",
          "lazy_outside_view" => "reads a lazy key outside a view",
          "custom_separator" => "uses a custom separator",
          "splat" => "passes options the scan can't read",
          "argument" => "passes the key through a method the scan can't follow",
          "concatenated_literal" => "builds a key from adjacent strings",
          "interpolation" => "builds a key by interpolation",
          "variable" => "reads a key from a variable",
          "constant" => "reads a key from a constant",
          "method_call" => "reads a key from a method call"
        }.fetch(reason, "reads a key the scan can't resolve")
      end
    end
  end
end
