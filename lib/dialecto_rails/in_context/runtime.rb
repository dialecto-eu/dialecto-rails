require_relative "../config"
require_relative "store"
require_relative "key_index"
require_relative "marking"
require_relative "git_context"
require_relative "backend_hook"
require_relative "sanitizer"
require_relative "middleware"
require_relative "csp"

module DialectoRails
  module InContext
    # The development-only machinery, built once the Railtie's guard has passed (spec-0023 §7.1).
    # Nothing in this folder is required before that, so a production process holds none of it.
    class Runtime
      attr_reader :config, :store, :index, :marking, :git_context

      def self.html_sanitizer = Sanitizer.build

      def initialize(root:, config:, logger: nil, sanitizer: self.class.html_sanitizer)
        @config = config
        @logger = logger
        @store = Store.new
        @index = KeyIndex.new(root: root, catalog_paths: config.catalog_paths)
        @marking = Marking.new(store: @store, index: @index, skip_keys: -> { config.skip_keys }, sanitizer: sanitizer)
        @git_context = GitContext.new(root: root, project: config.project, catalogs: config.catalogs)
      end

      def middleware_options = {settings: config, store: store, git_context: git_context, logger: @logger}

      # Prepends the hook on the class of each file-based backend. Returns the classes hooked.
      def install_hook(backend = ::I18n.backend)
        BackendHook.marking = marking
        BackendHook.logger = @logger
        backends = backend.is_a?(::I18n::Backend::Chain) ? backend.backends : [backend]
        backends.filter_map do |member|
          unless member.is_a?(::I18n::Backend::Simple)
            @logger&.info("dialecto-rails: in-context editing skipped #{member.class}: it isn't a file backend")
            next
          end
          klass = member.class
          klass.prepend(BackendHook) unless klass.ancestors.include?(BackendHook)
          klass
        end
      end

      def allow_overlay_in(policies)
        policies.each { |policy| Csp.allow(policy, config.url) if policy }
      end
    end
  end
end
