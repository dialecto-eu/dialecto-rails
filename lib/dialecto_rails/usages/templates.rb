module DialectoRails
  module Usages
    # Template languages reduced to the Ruby inside them, with every byte kept where it was, so an offset in
    # the reduced text is an offset in the template.
    module Templates
      # A template construct whose Ruby can't be put back in place; the message holds a line number, never source.
      Unreadable = Class.new(StandardError)

      module_function

      def erb(bytes)
        require "herb"
        Herb.extract_ruby(bytes)
      end

      # HAML is read when the app's bundle has the `haml` gem; nil otherwise.
      def haml(bytes)
        return nil unless haml_loadable?

        require_relative "haml_extractor"
        HamlExtractor.extract(bytes)
      end

      def haml_loadable?
        return @haml_loadable unless @haml_loadable.nil?

        @haml_loadable = begin
          require "haml"
          true
        rescue LoadError
          false
        end
      end

      def herb_version
        require "herb"
        Herb::VERSION
      rescue LoadError
        nil
      end

      def haml_version = haml_loadable? ? Haml::VERSION : nil
    end
  end
end
