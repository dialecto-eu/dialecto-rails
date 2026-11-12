require "prism"
require_relative "record"

module DialectoRails
  module Usages
    # Reads the key argument of a translate call (spec-0023 §6.3): what text it can name, which literals carry
    # that text, and why it can't be resolved when it can't.
    #
    #   :static     one key (`text`), with its literal if the literal can be rewritten
    #   :set        an exact list of `keys` (a ternary, an `||`, an array, an interpolation over a literal list)
    #   :pattern    literal parts around unknown ones (`items`), with the head literal
    #   :unresolved nothing to read (`reason`)
    #   :param      the key is one of a wrapper's parameters (`index`), only when `params` is given
    #
    # `items` hold `{lit:}`, `{wild: true}` and, for a wrapper, `{param: index}`.
    module Keys
      Analysis = Struct.new(:kind, :text, :items, :keys, :literals, :reason, :index, keyword_init: true)

      MAX_KEYS = 5_000
      TRANSPARENT = %i[to_s to_sym to_str].freeze

      module_function

      # `env`: local name → literal values (a block parameter over a literal list). `params`: local name →
      # positional index, when scouting a wrapper's body.
      def analyze(node, env: {}, params: nil, role: :key)
        case node
        when Prism::StringNode then static_string(node, role)
        when Prism::SymbolNode then static_symbol(node, role)
        when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then interpolated(node, env, params, role)
        when Prism::ParenthesesNode then parenthesized(node, env, params, role)
        when Prism::ArrayNode then choices(node.elements, env, params, role)
        when Prism::OrNode then choices([node.left, node.right], env, params, role)
        when Prism::IfNode then choices(branches(node), env, params, role)
        when Prism::LocalVariableReadNode
          if params&.key?(node.name)
            Analysis.new(kind: :param, index: params[node.name], items: [{param: params[node.name]}])
          else
            unresolved(:variable)
          end
        when Prism::InstanceVariableReadNode, Prism::ClassVariableReadNode, Prism::GlobalVariableReadNode
          unresolved(:variable)
        when Prism::ConstantReadNode, Prism::ConstantPathNode then unresolved(:constant)
        when Prism::CallNode
          return unresolved(:variable) if node.variable_call?
          return concatenated(node, env, params, role) if concatenation?(node)

          transparent?(node) ? analyze(node.receiver, env: env, params: params, role: role) : unresolved(:method_call)
        else unresolved(:variable)
        end
      end

      def unresolved(reason) = Analysis.new(kind: :unresolved, reason: reason, items: [{wild: true}], literals: [])

      def transparent?(node)
        node.receiver && TRANSPARENT.include?(node.name) && node.arguments.nil? &&
          (node.receiver.is_a?(Prism::LocalVariableReadNode))
      end

      # `"users." + role`: a string literal on the left of `+` with one argument. It names the same keys as
      # `"users.#{role}"`, so it locks the same family. It carries no head literal: the contract's head span
      # ends where an interpolation begins, so a group rename that reaches this call is refused, not rewritten.
      def concatenation?(node)
        node.name == :+ && node.receiver.is_a?(Prism::StringNode) && node.block.nil? &&
          node.arguments&.arguments&.length == 1
      end

      def concatenated(node, env, params, role)
        rest = analyze(node.arguments.arguments.first, env: env, params: params, role: role)
        tail = rest.kind == :param ? {param: rest.index} : {wild: true}
        Analysis.new(kind: :pattern, items: [{lit: node.receiver.unescaped}, tail], literals: [],
          reason: :interpolation)
      end

      def parenthesized(node, env, params, role)
        body = node.body
        statements = body.is_a?(Prism::StatementsNode) ? body.body : []
        statements.length == 1 ? analyze(statements.first, env: env, params: params, role: role) : unresolved(:variable)
      end

      def branches(node)
        out = []
        out.concat(node.statements&.body.to_a.last(1))
        tail = node.subsequent
        case tail
        when Prism::ElseNode then out.concat(tail.statements&.body.to_a.last(1))
        when Prism::IfNode then out.concat(branches(tail))
        end
        out
      end

      # `cond ? "a" : "b"`, `"a" || "b"`, `[:a, :b]`: each literal branch is a use.
      def choices(nodes, env, params, role)
        analyses = nodes.map { |branch| analyze(branch, env: env, params: params, role: role) }
        return unresolved(:variable) if analyses.empty? || analyses.any? { |item| item.kind != :static }

        keys = analyses.map(&:text).uniq.sort
        items = common_items(keys)
        Analysis.new(kind: :set, keys: keys, items: items, literals: analyses.flat_map(&:literals))
      end

      # The segments every key shares at the start and at the end; whatever lies between is wild.
      def common_items(keys)
        return [{lit: keys.first}] if keys.length == 1

        split = keys.map { |key| key.split(".", -1) }
        head = split.first.zip(*split.drop(1)).take_while { |segments| segments.uniq.length == 1 }.length
        tail_limit = split.map(&:length).min - head
        tail = 0
        tail += 1 while tail < tail_limit && split.map { |segments| segments[-1 - tail] }.uniq.length == 1
        items = []
        items << {lit: split.first.first(head).join(".") + "."} if head.positive?
        items << {wild: true}
        items << {lit: "." + split.first.last(tail).join(".")} if tail.positive?
        items
      end

      def static_string(node, role)
        opening = node.opening_loc&.slice
        text = node.unescaped
        literal = nil
        if ['"', "'"].include?(opening) && node.content_loc.slice == text
          literal = Literal.new(text_start: node.content_loc.start_offset, text_end: node.content_loc.end_offset,
            delim: opening, role: role, anchor_end: node.location.end_offset)
        end
        Analysis.new(kind: :static, text: text, items: [{lit: text}], literals: [literal].compact)
      end

      def static_symbol(node, role)
        opening = node.opening_loc&.slice
        text = node.unescaped
        literal = nil
        if [":", ':"', ":'"].include?(opening) && node.value_loc && node.value_loc.slice == text
          literal = Literal.new(text_start: node.value_loc.start_offset, text_end: node.value_loc.end_offset,
            delim: opening, role: role, anchor_end: node.location.end_offset)
        end
        Analysis.new(kind: :static, text: text, items: [{lit: text}], literals: [literal].compact)
      end

      def interpolated(node, env, params, role)
        parts = node.parts
        if node.opening_loc.nil? && parts.all?(Prism::StringNode)
          return unresolved(:concatenated_literal)
        end

        items = []
        values = []
        parts.each do |part|
          case part
          when Prism::StringNode
            items << {lit: part.unescaped}
            values << [part.unescaped]
          when Prism::EmbeddedStatementsNode
            resolved = embedded(part, env, params)
            if resolved.is_a?(Array)
              items << {wild: true}
              values << resolved
            elsif resolved.is_a?(Integer)
              items << {param: resolved}
              values << nil
            else
              items << {wild: true}
              values << nil
            end
          else
            items << {wild: true}
            values << nil
          end
        end

        literal = head_literal(node, role)
        if values.none?(&:nil?)
          keys = values.inject([""]) { |acc, options| acc.product(options).map(&:join) }.uniq.sort
          if keys.length <= MAX_KEYS
            return Analysis.new(kind: :set, keys: keys, items: items, literals: [literal].compact, reason: :interpolation)
          end
        end
        Analysis.new(kind: :pattern, items: items, literals: [literal].compact, reason: :interpolation)
      end

      # An embedded `#{...}`: the literal values a loop variable stands for (Array), a wrapper parameter's
      # index (Integer), or nil.
      def embedded(part, env, params)
        statements = part.statements&.body
        return nil unless statements&.length == 1

        node = statements.first
        node = node.receiver if node.is_a?(Prism::CallNode) && transparent?(node)
        return nil unless node.is_a?(Prism::LocalVariableReadNode)
        return env[node.name] if env.key?(node.name)

        params&.fetch(node.name, nil)
      end

      def head_literal(node, role)
        first = node.parts.first
        opening = node.opening_loc&.slice
        return nil unless first.is_a?(Prism::StringNode) && [%("), ':"'].include?(opening)
        return nil unless first.location.slice == first.unescaped

        Literal.new(text_start: first.location.start_offset, text_end: first.location.end_offset,
          delim: opening, role: role, head: true, anchor_end: node.location.end_offset)
      end
    end
  end
end
