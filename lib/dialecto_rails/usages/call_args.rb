require "prism"

module DialectoRails
  module Usages
    # What a translate call is made of: its positional arguments and the options of its trailing keyword hash.
    module CallArgs
      Options = Struct.new(:scope, :default, :separator, :splat, keyword_init: true)

      TRANSLATE_NAMES = %i[t translate t! translate!].freeze
      HELPER_RECEIVERS = %i[helpers view_context view controller].freeze

      module_function

      def positional(call)
        arguments = call.arguments&.arguments || []
        arguments.reject { |argument| argument.is_a?(Prism::KeywordHashNode) }
      end

      def keyword_hash(call)
        (call.arguments&.arguments || []).find { |argument| argument.is_a?(Prism::KeywordHashNode) }
      end

      # `forward`: names of the enclosing method's own `*rest`, `**opts` and `&block`, whose splats pass the
      # caller's options straight on and say nothing about the key.
      def options(call, forward: [])
        options = Options.new(splat: false)
        keyword_hash(call)&.elements&.each do |element|
          case element
          when Prism::AssocNode
            name = element.key.is_a?(Prism::SymbolNode) ? element.key.unescaped : nil
            case name
            when "scope" then options.scope = element.value
            when "default" then options.default = element.value
            when "separator" then options.separator = element.value
            end
          when Prism::AssocSplatNode
            value = element.value
            forwarded = value.is_a?(Prism::LocalVariableReadNode) && forward.include?(value.name)
            options.splat = true unless forwarded
          end
        end
        positional(call).drop(1).each do |extra|
          options.splat = true if extra.is_a?(Prism::LocalVariableReadNode) || extra.is_a?(Prism::InstanceVariableReadNode)
        end
        options
      end

      def const_named?(node, name)
        case node
        when Prism::ConstantReadNode then node.name == name
        when Prism::ConstantPathNode then node.parent.nil? && node.name == name
        else false
        end
      end

      # `Spree`, `::Spree` and `Admin::Helpers` as written (a leading `::` dropped), or nil for anything else.
      def const_path(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent.nil? ? "" : const_path(node.parent)
          parent && (parent.empty? ? node.name.to_s : "#{parent}::#{node.name}")
        end
      end

      # :none for a bare call (or `self.`), :i18n for `I18n.`, :helper for `helpers.`, `view_context.`…
      # and :other for anything else.
      def receiver_kind(call)
        receiver = call.receiver
        return :none if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        return :i18n if const_named?(receiver, :I18n)
        return :helper if receiver.is_a?(Prism::CallNode) && HELPER_RECEIVERS.include?(receiver.name)

        :other
      end
    end
  end
end
