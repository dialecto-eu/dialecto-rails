require_relative "../config"
require_relative "../unmarked"
require_relative "live_store"
require_relative "key_index"
require_relative "marking"
require_relative "backend_hook"
require_relative "sanitizer"
require_relative "live_middleware"

module DialectoRails
  module InContext
    # The production machinery of live-site editing, built only after the Railtie has checked that live mode
    # is configured (spec-0025 §4). It holds none of the development pieces: no store of drafts, no git
    # context, no endpoints.
    class LiveRuntime
      # A marked request neither reads nor writes fragments: a cold fragment rendered for an editor would be
      # cached with its markers and served to every visitor.
      module NoFragmentCaching
        def perform_caching = ::DialectoRails.live_marking? ? false : super
      end

      attr_reader :config, :marking

      def initialize(root:, config:, logger: nil, sanitizer: Sanitizer.build)
        @config = config
        @logger = logger
        index = KeyIndex.new(root: root, catalog_paths: config.catalog_paths)
        @marking = Marking.new(store: LiveStore.new, index: index, skip_keys: -> { config.skip_keys }, sanitizer: sanitizer)
      end

      def middleware_options = {settings: config, logger: @logger}

      # Prepends the hook on each file-based backend, gated on the thread's flag so a visitor's lookups take
      # the plain path.
      def install_hook(backend = ::I18n.backend)
        BackendHook.marking = marking
        BackendHook.logger = @logger
        BackendHook.gate = -> { ::DialectoRails.live_marking? }
        ::ActiveSupport.on_load(:action_controller_base) do
          prepend NoFragmentCaching unless ancestors.include?(NoFragmentCaching)
        end
        backends = backend.is_a?(::I18n::Backend::Chain) ? backend.backends : [backend]
        backends.filter_map do |member|
          next unless member.is_a?(::I18n::Backend::Simple)

          klass = member.class
          klass.prepend(BackendHook) unless klass.ancestors.include?(BackendHook)
          klass
        end
      end
    end
  end
end
