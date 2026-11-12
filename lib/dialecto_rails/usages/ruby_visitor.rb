require "prism"
require_relative "record"
require_relative "keys"
require_relative "call_args"
require_relative "lazy_scope"
require_relative "wrappers"

module DialectoRails
  module Usages
    # Walks one Ruby program (a `.rb` file, or the Ruby a template was reduced to, with the same byte offsets as
    # the file) and returns the usage records, mailer subject conventions and `literal` sweep hits in it.
    class RubyVisitor < Prism::Visitor
      LOOP_METHODS = %i[each map flat_map collect each_with_index filter_map select reject].freeze
      VISIBILITIES = %i[public private protected].freeze
      MAX_LITERAL = 160
      # Wrappers are found by name, so test code (`raise_error "msg"` matchers) must not match them.
      TEST_FILE = %r{(?:\A|/)(?:test|spec|features)/}

      Result = Struct.new(:records, :conventions, keyword_init: true)

      # A bare `Struct` standing in for an `Anchor` where the bytes are already decided.
      Span = Struct.new(:start, :finish)

      def self.literal_values(node)
        return nil unless node.is_a?(Prism::ArrayNode)

        values = node.elements.map do |element|
          element.unescaped if element.is_a?(Prism::StringNode) || element.is_a?(Prism::SymbolNode)
        end
        values.empty? || values.any?(&:nil?) ? nil : values
      end

      def initialize(file:, lang:, bytes:, wrappers:, catalog:, i18n_functions: [])
        super()
        @file = file
        @lang = lang
        @bytes = bytes
        @lines = LineIndex.new(bytes)
        @wrappers = wrappers
        @catalog = catalog
        @i18n_functions = i18n_functions.map(&:to_sym)
        @records = []
        @conventions = []
        @consumed = {}
        @classes = []
        @defs = []
        @env = {}
        @arrays = {}
        @constants = {}
        @visibilities = {}
      end

      def call(program)
        @constants = ConstantCollector.run(program)
        visit(program)
        Result.new(records: @records, conventions: @conventions)
      end

      # Collects `NAME = %w[a b]` (optionally `.freeze`d), so a loop over the constant resolves to its values.
      class ConstantCollector < Prism::Visitor
        def self.run(program)
          collector = new
          collector.visit(program)
          collector.found.compact
        end

        attr_reader :found

        def initialize
          super
          @found = {}
        end

        def visit_constant_write_node(node)
          value = node.value
          value = value.receiver if value.is_a?(Prism::CallNode) && value.name == :freeze && value.receiver
          @found[node.name] = RubyVisitor.literal_values(value)
          super
        end
      end

      ## Context

      def visit_class_node(node)
        names = node.constant_path.slice.split("::")
        enter_scope(names, LazyScope.kind(names.last, node.superclass&.slice), node) { super }
      end

      def visit_module_node(node)
        enter_scope(node.constant_path.slice.split("::"), nil, node) { super }
      end

      def visit_def_node(node)
        display = node.receiver ? "#{node.receiver.slice}.#{node.name}" : node.name.to_s
        parameters = node.parameters
        forward = [parameters&.rest, parameters&.keyword_rest, parameters&.block].filter_map { |item| item.name if item.respond_to?(:name) }
        @defs << {name: node.name.to_s, display: display, forward: forward,
                  visibility: @visibilities[node.location.start_offset] || :public}
        super
      ensure
        @defs.pop
      end

      def visit_local_variable_write_node(node)
        values = self.class.literal_values(node.value)
        values ? @arrays[node.name] = values : @arrays.delete(node.name)
        super
      end

      def visit_call_node(node)
        binding = loop_binding(node)
        saved = @env
        @env = @env.merge(binding) if binding
        handle(node)
        super
      ensure
        @env = saved
      end

      def visit_string_node(node)
        sweep(node)
        super
      end

      def visit_symbol_node(node)
        sweep(node)
        super
      end

      # The parts of `"users.#{role}"` are not strings in their own right.
      def visit_interpolated_string_node(node)
        node.parts.each { |part| @consumed[part.location.start_offset] = true if part.is_a?(Prism::StringNode) }
        super
      end

      def visit_interpolated_symbol_node(node)
        node.parts.each { |part| @consumed[part.location.start_offset] = true if part.is_a?(Prism::StringNode) }
        super
      end

      private

      def enter_scope(names, kind, node)
        nesting = @classes.flat_map { |frame| frame[:names] } + names
        @classes << {names: names, kind: kind, nesting: nesting}
        record_visibilities(node.body)
        yield
      ensure
        @classes.pop
      end

      # Which methods of a class body are public, private or protected: the bare `private`, `private def` and
      # `private :name` forms.
      def record_visibilities(body)
        statements = body.is_a?(Prism::StatementsNode) ? body.body : []
        state = :public
        named = {}
        statements.each do |statement|
          case statement
          when Prism::CallNode
            next unless statement.receiver.nil? && VISIBILITIES.include?(statement.name)

            arguments = statement.arguments&.arguments || []
            if arguments.empty?
              state = statement.name
            else
              arguments.each do |argument|
                case argument
                when Prism::DefNode then @visibilities[argument.location.start_offset] = statement.name
                when Prism::SymbolNode then named[argument.unescaped] = statement.name
                end
              end
            end
          when Prism::DefNode
            @visibilities[statement.location.start_offset] ||= state
          end
        end
        statements.grep(Prism::DefNode).each do |definition|
          visibility = named[definition.name.to_s]
          @visibilities[definition.location.start_offset] = visibility if visibility
        end
      end

      def loop_binding(node)
        return nil unless LOOP_METHODS.include?(node.name) && node.block.is_a?(Prism::BlockNode)

        return nil unless node.block.parameters.is_a?(Prism::BlockParametersNode)

        parameter = node.block.parameters.parameters&.requireds&.first
        return nil unless parameter.is_a?(Prism::RequiredParameterNode)

        values = case (receiver = node.receiver)
        when Prism::ArrayNode then self.class.literal_values(receiver)
        when Prism::ConstantReadNode then @constants[receiver.name]
        when Prism::LocalVariableReadNode then @arrays[receiver.name]
        end
        values ? {parameter.name => values} : nil
      end

      def fn = @defs.last&.dig(:display)

      def class_frame = @classes.reverse.find { |frame| frame[:kind] }

      ## Calls

      def handle(node)
        wrapped = @wrappers.suppressed(@file, node.location.start_offset)
        unless wrapped.nil?
          emit_template(node, wrapped) if wrapped
          return
        end

        track_mail(node)
        receiver = CallArgs.receiver_kind(node)
        return receiver_call(node) if receiver == :other

        form, origin = translate_form(node, receiver)
        positional = CallArgs.positional(node)
        if form
          translate_record(node, positional.first, form, origin) if positional.first
        elsif receiver == :none && !positional.empty? && !TEST_FILE.match?(@file) && (builders = @wrappers.lookup(node.name, file: @file, klass: @classes.last&.dig(:names)&.last))
          wrapper_call(node, positional, builders)
        end
      end

      # A call on a constant (`Spree.t("x")`, `::Spree.t`): a use when the constant's method is a wrapper, found in
      # the source or declared (spec-0023 §6.3).
      def receiver_call(node)
        path = CallArgs.const_path(node.receiver)
        return unless path && !TEST_FILE.match?(@file)

        positional = CallArgs.positional(node)
        builders = !positional.empty? && @wrappers.lookup_receiver(path, node.name)
        wrapper_call(node, positional, builders, form: "#{path}.#{node.name}") if builders
      end

      def translate_form(node, receiver)
        name = node.name
        if receiver == :i18n
          ["I18n.#{name}", "i18n"] if CallArgs::TRANSLATE_NAMES.include?(name) || name == :exists?
        elsif CallArgs::TRANSLATE_NAMES.include?(name)
          [name.to_s, "helper"]
        elsif receiver == :none && @i18n_functions.include?(name)
          [name.to_s, "name"]
        end
      end

      ## A translate call

      def translate_record(node, key_node, form, origin)
        options = CallArgs.options(node, forward: @defs.last&.dig(:forward) || [])
        analysis = Keys.analyze(key_node, env: @env)
        # A message with spaces is not a key: a wrapper found by name can collide with an unrelated method.
        return if origin == "wrapper" && analysis.kind == :static && analysis.text.match?(/\s/)
        # A test's own `t "<p>text</p>"` helper (a typography spec) is not a key.
        return if origin == "helper" && TEST_FILE.match?(@file) && analysis.kind == :static && analysis.text.match?(/[\s<\\]/)
        return star(node, form, origin, "custom_separator") if custom_separator?(options.separator)
        return star(node, form, origin, "concatenated_literal") if analysis.reason == :concatenated_literal

        text = analysis.kind == :static ? analysis.text : analysis.items&.first&.dig(:lit)
        if origin == "i18n"
          analysis = without_leading_dots(analysis)
          lazy = nil
        else
          lazy = lazy_context(analysis) if text.to_s.start_with?(".") && analysis.kind != :set
        end

        prefix, scope, scope_literals, reasons = lazy ? lazy_prefix(lazy) : scope_prefix(options)
        defaults, default_literals = defaults_for(options, prefix, lazy)
        literals = analysis.literals.to_a + scope_literals + default_literals
        build(node, form, origin, analysis, prefix: prefix, lazy: lazy, reasons: reasons, scope: scope,
          defaults: defaults, literals: literals)
        [key_node, options.scope, options.default].each { |argument| consume(argument) }
      end

      # `I18n.t(".x")` outside a view has no lazy meaning: I18n drops the empty segment (spec-0023 §6.4).
      def without_leading_dots(analysis)
        return analysis unless analysis.kind == :static && analysis.text.start_with?(".")

        stripped = analysis.text.sub(/\A\.+/, "")
        Keys::Analysis.new(kind: :static, text: stripped, items: [{lit: stripped}], literals: [])
      end

      def custom_separator?(separator)
        !separator.nil? && !(separator.is_a?(Prism::StringNode) && separator.unescaped == ".")
      end

      # Returns [prefix items, scope entries (or nil), scope literals, reasons].
      def scope_prefix(options)
        return [[{wild: true}, {lit: "."}], nil, [], [:splat]] if options.splat
        return [[], nil, [], []] unless options.scope

        items = []
        entries = []
        literals = []
        reasons = []
        scope_elements(options.scope).each do |element|
          if element[:literal]
            literals << element[:literal]
            entries << {literal: element[:literal]}
            items << {lit: i18n_path(element[:text]) + "."}
          else
            entries << {expr: element[:expr]}
            items << {wild: true} << {lit: "."}
            reasons << :dynamic_scope
          end
        end
        [items, entries, literals, reasons]
      end

      def scope_elements(node)
        nodes = node.is_a?(Prism::ArrayNode) ? node.elements : [node]
        nodes.map do |element|
          literal = [Prism::StringNode, Prism::SymbolNode].any? { |type| element.is_a?(type) }
          analysis = literal ? Keys.analyze(element, role: :scope) : nil
          if analysis && !analysis.text.empty? && analysis.literals.length == 1
            {literal: analysis.literals.first, text: analysis.text}
          else
            {expr: element.slice.byteslice(0, 200).scrub("")}
          end
        end
      end

      # The key's prefix for a lazy call: where Rails resolves it from, decided by the file and the class.
      def lazy_prefix(lazy)
        case lazy[:type]
        when :view then [[{lit: lazy[:base]}], nil, [], []]
        when :action then [[{lit: "#{lazy[:path]}.#{lazy[:action]}"}], nil, [], []]
        when :unknown then [[{lit: "#{lazy[:path]}."}, {wild: true}], nil, [], [:lazy_action_unknown]]
        else [[{wild: true}], nil, [], [:lazy_outside_view]]
        end
      end

      def lazy_context(analysis)
        key = analysis.kind == :static ? analysis.text : nil
        view = LazyScope.view(@file)
        return {type: :view, base: view[:base], from: view[:from], key: key} if view

        frame = class_frame
        return {type: :outside, from: "other", key: key} unless frame

        kind = frame[:kind]
        path = LazyScope.path(frame[:nesting].join("::"), kind)
        current = @defs.last
        if current && LazyScope.action?(kind, current[:name], current[:visibility])
          {type: :action, path: path, action: current[:name], from: kind.to_s, key: key}
        else
          {type: :unknown, path: path, from: kind.to_s, key: key}
        end
      end

      def defaults_for(options, prefix, lazy)
        out = []
        literals = []
        if lazy
          out << {key: "#{lazy[:path]}#{lazy[:key]}"} if %i[action unknown].include?(lazy[:type]) && lazy[:key]
          return [out, literals]
        end
        return [out, literals] if !options.default || prefix.any? { |item| item[:wild] }

        base = prefix.map { |item| item[:lit] }.join
        nodes = options.default.is_a?(Prism::ArrayNode) ? options.default.elements : [options.default]
        nodes.each do |element|
          next unless element.is_a?(Prism::SymbolNode)

          analysis = Keys.analyze(element, role: :default)
          literal = analysis.literals.first
          literals << literal if literal
          out << {key: base + analysis.text, literal: literal}
        end
        [out, literals]
      end

      ## Building a record

      def build(node, form, origin, analysis, prefix:, lazy:, reasons:, scope:, defaults:, literals:)
        items = prefix + (analysis.items || [{wild: true}])
        unresolved = analysis.kind == :unresolved
        kind = if prefix.any? { |item| item[:wild] } || %i[pattern unresolved].include?(analysis.kind) then :pattern
        elsif analysis.kind == :set then :set
        else :static
        end

        anchor = Anchor.new(start: node.location.start_offset, call_end: node.location.end_offset, literals: literals)
        return star(node, form, origin, "anchor_too_long", truncate: true) if anchor.too_long?

        record = base_record(node, anchor, form, origin)
        record["kind"] = kind.to_s
        base = prefix.reject { |item| item[:wild] }.map { |item| item[:lit] }.join
        case kind
        when :static
          record["key"] = i18n_path(base + analysis.text)
        when :set
          record["keys"] = analysis.keys.map { |key| i18n_path(base + key) }.sort
          assign_pattern(record, prefix + analysis.items)
        else
          assign_pattern(record, items)
          reason = (unresolved ? analysis.reason : nil) || reasons.first || analysis.reason || :variable
          record["reason"] = reason.to_s
        end

        record["lazy"] = lazy_json(lazy) if lazy
        record["scope"] = scope_json(scope, anchor) if scope && !scope.empty?
        unless defaults.empty?
          record["defaults"] = defaults.map do |entry|
            index = entry[:literal] && anchor.index_of(entry[:literal])
            index ? {"key" => entry[:key], "span" => index} : {"key" => entry[:key]}
          end
        end
        record["spans"] = anchor.spans
        @records << record
      end

      # I18n splits a key and every scope element on "." and drops the empty segments
      # (`I18n.normalize_keys`): `scope: "users."` and `t("a..b")` read as `users.x` and `a.b`.
      def i18n_path(text) = text.split(".").reject(&:empty?).join(".")

      def scope_json(scope, anchor)
        scope.map { |entry| entry[:literal] ? {"span" => anchor.index_of(entry[:literal])} : {"expr" => entry[:expr]} }
      end

      def lazy_json(lazy)
        json = {"from" => lazy[:from]}
        case lazy[:type]
        when :view then json["base"] = lazy[:base]
        when :action then json["base"] = "#{lazy[:path]}.#{lazy[:action]}"
        end
        json
      end

      def assign_pattern(record, items)
        parts = Parts.build(items)
        record["pattern"] = Parts.pattern(parts)
        record["parts"] = Parts.json(parts)
      end

      def base_record(node, anchor, form, origin)
        start = anchor.start
        content = slice(start, anchor.finish)
        record = {
          "file" => @file, "lang" => @lang, "start_line" => @lines.line_of(start),
          "end_line" => @lines.line_of(start) + content.count("\n"), "offset" => start, "content" => content,
          "form" => form, "fn" => fn
        }
        record["origin"] = origin if origin
        record
      end

      def slice(start, finish) = @bytes.byteslice(start, finish - start).dup.force_encoding(Encoding::UTF_8)

      # A pattern `*` record: the key can't be read, so the anchor runs to the call's closing parenthesis and
      # there are no spans.
      def star(node, form, origin, reason, truncate: false, templates: nil, finish: nil)
        start = node.location.start_offset
        finish ||= node.location.end_offset
        if truncate && finish - start > Anchor::MAX_BYTES
          bytes = @bytes.byteslice(start, Anchor::MAX_BYTES).dup.force_encoding(Encoding::UTF_8)
          bytes = bytes.byteslice(0, bytes.bytesize - 1).force_encoding(Encoding::UTF_8) until bytes.valid_encoding?
          finish = start + bytes.bytesize
        end
        record = base_record(node, Span.new(start, finish), form, origin)
        record["kind"] = "pattern"
        record["pattern"] = "*"
        record["parts"] = [{"wild" => true}]
        record["reason"] = reason
        record["via"] = templates if templates && !templates.empty?
        record["spans"] = []
        @records << record
        consume(node.arguments)
      end

      ## Wrapper calls and templates

      def wrapper_call(node, positional, builders, form: node.name.to_s)
        options = CallArgs.options(node, forward: @defs.last&.dig(:forward) || [])
        templates = builders.flat_map(&:templates).uniq
        builder = builders.length == 1 ? builders.first : nil
        return unless key_arguments_plausible?(builders, positional)

        if builder&.pass_through? && positional[builder.items.first[:param]]
          return translate_record(node, positional[builder.items.first[:param]], form, "wrapper")
        end
        if builder.nil? || builder.opaque || options.scope || options.splat || options.separator
          return fixed_pattern(node, form, builder.fixed, templates) if builder&.fixed

          return star(node, form, "wrapper", "argument", templates: templates)
        end

        analyses = positional.map { |argument| Keys.analyze(argument, env: @env) }
        used = builder.items.filter_map { |item| item[:param] }.uniq
        known = builder.items.none? { |item| item[:wild] } && used.all? { |index| analyses[index] && %i[static set].include?(analyses[index].kind) }
        substituted = builder.items.flat_map do |item|
          next [item] unless item.key?(:param)

          argument = analyses[item[:param]]
          argument && %i[static set pattern].include?(argument.kind) ? argument.items : [{wild: true}]
        end

        extra_end = used.filter_map { |index| positional[index]&.location&.end_offset }.max
        anchor = Anchor.new(start: node.location.start_offset, call_end: node.location.end_offset, literals: [],
          extra_end: extra_end)
        record = base_record(node, anchor, form, "wrapper")
        if known
          keys = expand_keys(builder.items, analyses)
          record["kind"] = "set"
          record["keys"] = keys
          assign_pattern(record, keys.length == 1 ? [{lit: keys.first}] : substituted)
        else
          record["kind"] = "pattern"
          assign_pattern(record, substituted)
          record["reason"] = "argument"
        end
        record["via"] = templates unless templates.empty?
        record["spans"] = []
        @records << record
        positional.each { |argument| consume(argument) }
      end

      # A declared wrapper whose key can't be read (`Spree.t(key, scope: x)`): it still reads under its own scope.
      def fixed_pattern(node, form, fixed, templates)
        anchor = Anchor.new(start: node.location.start_offset, call_end: node.location.end_offset, literals: [])
        return star(node, form, "wrapper", "argument", templates: templates) if anchor.too_long?

        record = base_record(node, anchor, form, "wrapper")
        record["kind"] = "pattern"
        assign_pattern(record, [{lit: fixed}, {wild: true}])
        record["reason"] = "argument"
        record["via"] = templates unless templates.empty?
        record["spans"] = []
        @records << record
        consume(node.arguments)
      end

      NOT_A_KEY =[Prism::IntegerNode, Prism::FloatNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
                   Prism::HashNode, Prism::RangeNode].freeze

      # A call that doesn't pass the argument the wrapper builds its key from, or passes a number or a sentence,
      # isn't reading a key: the wrapper was found by name, and the name may belong to another method.
      def key_arguments_plausible?(builders, positional)
        used = builders.flat_map { |builder| builder.items.filter_map { |item| item[:param] } }.uniq
        arguments = used.map { |index| positional[index] }
        return false if arguments.any?(&:nil?)

        arguments.none? do |argument|
          NOT_A_KEY.any? { |type| argument.is_a?(type) } ||
            (argument.is_a?(Prism::StringNode) && argument.unescaped.match?(/\s/))
        end
      end

      def expand_keys(items, analyses)
        options = items.map do |item|
          next [item[:lit]] if item.key?(:lit)

          argument = analyses[item[:param]]
          argument.kind == :static ? [argument.text] : argument.keys
        end
        options.inject([""]) { |acc, values| acc.product(values).map(&:join) }.uniq.sort
      end

      # Where a wrapper's text is written: the call inside the wrapper, cut at its first interpolation.
      def emit_template(node, wrapped)
        template = wrapped
        form = node.name.to_s
        form = "I18n.#{form}" if CallArgs.receiver_kind(node) == :i18n
        origin = CallArgs.receiver_kind(node) == :i18n ? "i18n" : "helper"
        record = base_record(node, Span.new(template.start, template.text_end), form, origin)
        record["kind"] = "template"
        record["id"] = template.id
        assign_pattern(record, Keys.analyze(CallArgs.positional(node).first).items)
        record["spans"] = [{"start" => template.literal.text_start - template.start,
                            "end" => template.literal.text_end - template.start, "delim" => template.literal.delim,
                            "role" => "key", "lang" => "ruby", "head" => true, "closed" => false}]
        @records << record
        consume(CallArgs.positional(node).first)
      end

      ## Mailer subjects

      def track_mail(node)
        return unless node.name == :mail && node.receiver.nil?

        frame = class_frame
        current = @defs.last
        return unless frame && frame[:kind] == :mailer && current && current[:visibility] == :public

        explicit = CallArgs.keyword_hash(node)&.elements&.any? do |element|
          element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) && element.key.unescaped == "subject"
        end
        return if explicit

        constant = frame[:nesting].join("::")
        @conventions << {
          "key" => "#{LazyScope.path(constant, :mailer)}.#{current[:name]}.subject", "reason" => "mailer_subject",
          "source" => "#{constant}##{current[:name]}", "file" => @file,
          "line" => @lines.line_of(node.location.start_offset)
        }
      end

      ## The sweep

      def consume(node)
        return unless node

        @consumed[node.location.start_offset] = true if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
        node.compact_child_nodes.each { |child| consume(child) }
      end

      def sweep(node)
        return if @catalog.nil? || @catalog.empty? || @consumed[node.location.start_offset]

        text = node.unescaped
        return if text.empty? || text.length >= MAX_LITERAL
        # A one-segment key ("name") is a word in half the strings of a codebase; the sweep wants a dotted key.
        return unless (text.include?(".") && @catalog.include?(text)) || @catalog.prefix?(text)
        return if node.opening_loc&.slice&.start_with?("<<")

        analysis = node.is_a?(Prism::StringNode) ? Keys.static_string(node, :key) : Keys.static_symbol(node, :key)
        anchor = Anchor.new(start: node.location.start_offset, call_end: node.location.end_offset,
          literals: analysis.literals)
        record = base_record(node, anchor, "literal", nil)
        record["kind"] = "literal"
        record["key"] = text
        record["spans"] = anchor.spans
        @records << record
      end
    end
  end
end
