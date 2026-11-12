module DialectoRails
  # The Rails integration (spec-0023 §7.1). This file is all a production process loads: every initializer
  # begins with a guard, and the in-context code is required only after one passes.
  class Railtie < ::Rails::Railtie
    config.dialecto = ActiveSupport::OrderedOptions.new

    # The development guard: development only, so test, staging and any custom environment get nothing, and
    # the environment or `config.dialecto.enabled = false` can switch it off. The mode may also say `:live` or
    # `:off`; unset it is `:dev` here.
    def self.active?(app)
      return false unless ::Rails.env.development?

      require "dialecto_rails/config"
      config = DialectoRails::Config.new(app.config.dialecto.to_h)
      config.enabled? && config.mode(:dev) == :dev
    end

    # The live guard (spec-0025 §4): any environment, but only when `mode` is `:live` and the repo, origin and
    # public key are set. Unset, the mode is `:off` outside development, so a production app is inert until its
    # config says otherwise.
    def self.live?(app)
      require "dialecto_rails/config"
      DialectoRails::Config.new(app.config.dialecto.to_h).live?(:off)
    end

    initializer "dialecto_rails.middleware" do |app|
      next unless DialectoRails::Railtie.active?(app)

      require "dialecto_rails/in_context/runtime"
      runtime = DialectoRails::InContext::Runtime.new(
        root: app.root, config: DialectoRails::Config.new(app.config.dialecto.to_h), logger: ::Rails.logger
      )
      app.config.dialecto.runtime = runtime
      app.middleware.insert_before 0, DialectoRails::InContext::Middleware, **runtime.middleware_options
    end

    initializer "dialecto_rails.live_middleware" do |app|
      unless DialectoRails::Railtie.live?(app)
        problems = DialectoRails::Config.new(app.config.dialecto.to_h).live_problems(:off)
        unless problems.empty?
          ::Rails.logger&.warn("dialecto-rails: mode :live stays off: #{problems.join("; ")}")
        end
        next
      end

      # The launch token travels in the URL of the first request; keep it out of the request log.
      app.config.filter_parameters += [:dialecto_edit]

      require "dialecto_rails/in_context/live_runtime"
      runtime = DialectoRails::InContext::LiveRuntime.new(
        root: app.root, config: DialectoRails::Config.new(app.config.dialecto.to_h), logger: ::Rails.logger
      )
      app.config.dialecto.live_runtime = runtime
      # After the session middleware, which the middleware reads and writes; an API-only app has none.
      if defined?(::ActionDispatch::Flash) && !app.config.api_only
        app.middleware.insert_before ::ActionDispatch::Flash, DialectoRails::InContext::LiveMiddleware, **runtime.middleware_options
      else
        app.middleware.use DialectoRails::InContext::LiveMiddleware, **runtime.middleware_options
      end
    end

    config.after_initialize do |app|
      if DialectoRails::Railtie.active?(app) && (runtime = app.config.dialecto.runtime)
        runtime.install_hook
        runtime.allow_overlay_in([app.config.content_security_policy, app.config.content_security_policy_report_only]
          .select { |policy| policy.respond_to?(:directives) })
        if app.config.action_controller.perform_caching
          ::Rails.logger.warn("dialecto-rails: fragment caching is on, so cached fragments carry no markers. " \
            "Run `bin/rails dev:cache` to turn it off while editing.")
        end
      elsif (runtime = app.config.dialecto.live_runtime)
        runtime.install_hook
      end
    end
  end
end
