module DialectoRails
  module InContext
    # The safe-list sanitizer for `_html` drafts. ActionView depends on rails-html-sanitizer, but loads it
    # lazily, so it is required here rather than found by `defined?`; if it can't load, the marking escapes
    # drafts instead (it fails closed).
    module Sanitizer
      module_function

      def build
        require "rails-html-sanitizer"
        klass = defined?(::Rails::HTML5::SafeListSanitizer) ? ::Rails::HTML5::SafeListSanitizer : ::Rails::Html::SafeListSanitizer
        sanitizer = klass.new
        ->(text) { sanitizer.sanitize(text) }
      rescue LoadError, NameError
        nil
      end
    end
  end
end
