require "prism"
require_relative "keys"
require_relative "call_args"

module DialectoRails
  module Usages
    # Wrapper methods (spec-0023 §6.3): a method whose parameter flows into a translate call's key
    # (`def tt(key) = t("nav.#{key}")`). The call inside the wrapper is not a use of its own: its literal head
    # becomes a `template` record, and each call to the wrapper becomes a use. Found by repeating until nothing
    # new is found, so a wrapper of a wrapper counts.
    class Wrappers
      # items: `{lit:}`, `{wild: true}` and `{param: index}`; templates: ids of the template records that hold
      # the text; opaque: the key can't be worked out (an option such as `scope:` changes it).
      # fixed: the key prefix a declared wrapper adds on its own (`Spree.t` reads under `spree.`), for a call whose
      # key can't be worked out (it is then a pattern under that prefix, not under everything).
      Builder = Struct.new(:items, :templates, :opaque, :fixed, keyword_init: true) do
        def pass_through? = !opaque && items.length == 1 && items.first.key?(:param)
      end

      # One translate-like call inside a method, whose key mentions the method's parameters.
      Call = Struct.new(:offset, :name, :kind, :items, :args, :opaque, :template, :template_id, keyword_init: true)

      # `owner`: the class or module the method sits in (`{name:, module:}`), nil at the top level. `receiver`: the
      # constant it is called on (`Spree` for `def self.t`, `class << self` or `module_function`), else nil.
      Definition = Struct.new(:file, :offset, :name, :calls, :builders, :owner, :receiver, keyword_init: true)

      # Where a template record is written: the key literal's start up to its first interpolation.
      Template = Struct.new(:start, :text_end, :literal, :id, keyword_init: true)

      # `declared`: methods called on a constant that the scan can't read the body of (a gem's `Spree.t`): hashes
      # of `receiver:` ("Spree"), `name:` ("t") and `scope:` ("spree" or nil). They take the key as their first
      # argument, like `t`, and put `scope` in front of it.
      def initialize(i18n_functions: [], declared: [])
        @i18n_functions = i18n_functions.map(&:to_sym)
        @definitions = []
        @table = {}
        @by_name = {}
        @parents = {}
        @aliases = []
        @declared = declared.map { |entry| [entry[:receiver], entry[:name].to_sym, declared_builder(entry[:scope])] }
      end

      def scout(file, program)
        Scout.new(file, @i18n_functions, @definitions, @parents, @aliases).visit(program)
      end

      # The builders of a wrapper called on a constant (`Spree.t("x")`, `::Spree.t`), or nil. A declared wrapper
      # matches the constant as written; one found in the source matches by the constant's last name.
      def lookup_receiver(path, name)
        name = name.to_sym
        builders = @declared.filter_map { |receiver, declared, builder| builder if receiver == path && declared == name }
        last = path.split("::").last
        (@by_name[name] || []).each { |definition, builder| builders << builder if definition.receiver == last }
        builders.uniq!
        builders.empty? ? nil : builders
      end

      def resolve!
        expand_aliases
        10.times do
          changed = false
          @definitions.each do |definition|
            builders = definition.calls.filter_map { |call| builder_for(call, definition) }.uniq
            next if builders.empty? || builders == definition.builders

            definition.builders = builders
            changed = true
          end
          rebuild_table
          break unless changed
        end
        self
      end

      # The builders of the wrappers a call can reach, or nil. A bare call reaches a method of its own file, of a
      # module (a helper or concern mixes in anywhere), of a class it descends from, or a top-level one. Without
      # this, `validate :x` in any model would match some unrelated `def validate(key)`. Several different
      # builders make the name ambiguous.
      def lookup(name, file:, klass: nil)
        reachable = (@by_name[name.to_sym] || []).select { |definition, _| reaches?(definition, file, klass) }
        builders = reachable.map(&:last).uniq
        builders.empty? ? nil : builders
      end

      def any? = !@table.empty?

      # [file, call offset] → the template that call writes, or false when it has none: the call is suppressed.
      def suppressed(file, offset)
        @suppressed ||= build_suppressed
        @suppressed[[file, offset]]
      end

      private

      def declared_builder(scope)
        prefix = Array(scope).map(&:to_s).reject(&:empty?).join(".")
        return Builder.new(items: [{param: 0}], templates: [], opaque: false) if prefix.empty?

        Builder.new(items: [{lit: "#{prefix}."}, {param: 0}], templates: [], opaque: false, fixed: "#{prefix}.")
      end

      # `alias t translate` and `alias_method :t, :translate` make a second name for a wrapper.
      def expand_aliases
        return if @aliases_done

        @aliases_done = true
        @aliases.each do |entry|
          @definitions.dup.each do |definition|
            next unless definition.file == entry[:file] && definition.name == entry[:old] &&
              definition.owner&.dig(:name) == entry[:owner]&.dig(:name)

            copy = definition.dup
            copy.name = entry[:new]
            copy.receiver = entry[:owner]&.dig(:name) if entry[:singleton]
            @definitions << copy
          end
        end
      end

      def build_suppressed
        out = {}
        @definitions.each do |definition|
          next if definition.builders.nil?

          definition.calls.each { |call| out[[definition.file, call.offset]] = call.template || false }
        end
        out
      end

      def rebuild_table
        @table = {}
        @by_name = {}
        @definitions.each do |definition|
          next if definition.builders.nil? || definition.builders.empty?

          (@table[definition.name.to_sym] ||= []).concat(definition.builders)
          definition.builders.each { |builder| (@by_name[definition.name.to_sym] ||= []) << [definition, builder] }
        end
        @table.each_value(&:uniq!)
      end

      def reaches?(definition, file, klass)
        owner = definition.owner
        return true if owner.nil? || owner[:module] || definition.file == file
        return true if definition.file.match?(%r{(?:\A|/)app/helpers/})

        ancestors?(klass, owner[:name])
      end

      # Does `klass` (a simple class name) descend from `owner`, by the superclasses seen in the scan?
      def ancestors?(klass, owner)
        seen = {}
        while klass && !seen[klass]
          return true if klass == owner

          seen[klass] = true
          klass = @parents[klass]
        end
        false
      end

      def builder_for(call, definition)
        if call.kind == :builtin
          return Builder.new(items: call.items, templates: [call.template_id].compact, opaque: true) if call.opaque

          return Builder.new(items: call.items, templates: [call.template_id].compact, opaque: false)
        end

        return nil if definition.name.to_sym == call.name.to_sym

        callee = lookup(call.name, file: definition.file, klass: definition.owner&.dig(:name))
        return nil if callee.nil?

        if callee.length != 1 || callee.first.opaque || call.opaque
          return Builder.new(items: [{wild: true}], templates: [], opaque: true)
        end

        built = callee.first
        items = built.items.flat_map do |item|
          item.key?(:param) ? (call.args[item[:param]] || [{wild: true}]) : [item]
        end
        Builder.new(items: items, templates: ([call.template_id] + built.templates).compact, opaque: false)
      end

      # Walks a file's methods, noting the translate-like calls whose key mentions a parameter.
      class Scout < Prism::Visitor
        def initialize(file, i18n_functions, definitions, parents, aliases)
          super()
          @file = file
          @i18n_functions = i18n_functions
          @definitions = definitions
          @parents = parents
          @aliases = aliases
          @frames = []
          @owners = []
          @singleton = 0
        end

        # `class << self` makes every method in it callable on the class.
        def visit_singleton_class_node(node)
          return super unless node.expression.is_a?(Prism::SelfNode)

          @singleton += 1
          super
        ensure
          @singleton -= 1 if node.expression.is_a?(Prism::SelfNode)
        end

        def visit_alias_method_node(node)
          note_alias(node.new_name, node.old_name)
          super
        end

        def visit_class_node(node)
          name = node.constant_path.slice.split("::").last
          superclass = node.superclass&.slice&.split("::")&.last
          @parents[name] ||= superclass if superclass
          @owners << {name: name, module: false}
          super
        ensure
          @owners.pop
        end

        def visit_module_node(node)
          @owners << {name: node.constant_path.slice.split("::").last, module: true, functions: module_functions(node)}
          super
        ensure
          @owners.pop
        end

        def visit_def_node(node)
          parameters = node.parameters
          params = {}
          positional = parameters ? parameters.requireds + parameters.optionals : []
          positional.each_with_index do |parameter, index|
            params[parameter.name] = index if parameter.respond_to?(:name) && parameter.name
          end
          forward = [parameters&.rest, parameters&.keyword_rest, parameters&.block].filter_map { |item| item.name if item.respond_to?(:name) }
          frame = {definition: Definition.new(file: @file, offset: node.location.start_offset, name: node.name.to_s,
            calls: [], owner: @owners.last, receiver: receiver_of(node)), params: params, forward: forward}
          @frames << frame
          super
          @frames.pop
          @definitions << frame[:definition] if !frame[:definition].calls.empty? && !params.empty?
        end

        def visit_call_node(node)
          frame = @frames.last
          note(node, frame) if frame
          note_alias(*node.arguments.arguments.first(2)) if node.name == :alias_method && node.receiver.nil? && node.arguments&.arguments&.length == 2
          super
        end

        private

        def note_alias(new_name, old_name)
          names = [new_name, old_name].map { |item| item.unescaped if item.is_a?(Prism::SymbolNode) }
          return if names.any?(&:nil?)

          @aliases << {file: @file, owner: @owners.last, new: names[0], old: names[1], singleton: @singleton > 0}
        end

        # The constant a method is called on: `def self.t`, `def Spree.t`, a method under `class << self`, or one
        # `module_function` (or `extend self`) turns into a module function. nil for an ordinary instance method.
        def receiver_of(node)
          owner = @owners.last
          case node.receiver
          when Prism::SelfNode then owner&.dig(:name)
          when nil
            functions = owner&.dig(:functions)
            callable = @singleton > 0 || functions == true || (functions.is_a?(Array) && functions.include?(node.name.to_s))
            owner&.dig(:name) if callable
          else CallArgs.const_path(node.receiver)&.split("::")&.last
          end
        end

        # `true` when the module says a bare `module_function` or `extend self`, else the names it lists.
        def module_functions(node)
          statements = node.body.respond_to?(:body) ? node.body.body : []
          names = []
          statements.each do |statement|
            next unless statement.is_a?(Prism::CallNode) && statement.receiver.nil?

            arguments = statement.arguments&.arguments || []
            return true if statement.name == :module_function && arguments.empty?
            return true if statement.name == :extend && arguments.first.is_a?(Prism::SelfNode)

            names.concat(arguments.filter_map { |item| item.unescaped if item.is_a?(Prism::SymbolNode) }) if statement.name == :module_function
          end
          names.empty? ? nil : names
        end

        def note(node, frame)
          return if frame[:params].empty?

          kind = kind_of(node)
          return unless kind

          positional = CallArgs.positional(node)
          key_node = positional.first
          return unless key_node

          analysis = Keys.analyze(key_node, params: frame[:params])
          return unless Array(analysis.items).any? { |item| item.key?(:param) }

          options = CallArgs.options(node, forward: frame[:forward])
          args = positional.map { |argument| Keys.analyze(argument, params: frame[:params]).items || [{wild: true}] }
          opaque = !options.scope.nil? || options.splat || !options.separator.nil?
          template = template_for(key_node, analysis)
          frame[:definition].calls << Call.new(offset: node.location.start_offset, name: node.name.to_s,
            kind: kind, items: analysis.items, args: args, opaque: opaque, template: template,
            template_id: template&.id)
        end

        def kind_of(node)
          receiver = CallArgs.receiver_kind(node)
          return nil if receiver == :other

          if CallArgs::TRANSLATE_NAMES.include?(node.name) || (receiver == :i18n && node.name == :exists?)
            :builtin
          elsif receiver == :none
            @i18n_functions.include?(node.name) ? :builtin : :wrapper_call
          end
        end

        def template_for(key_node, analysis)
          head = analysis.literals&.find(&:head?)
          return nil unless head

          start = key_node.location.start_offset
          Template.new(start: start, text_end: head.text_end, literal: head, id: "#{@file}@#{start}")
        end
      end
    end
  end
end
