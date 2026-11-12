require "json"
require_relative "marker"

module DialectoRails
  module InContext
    # What a marker records about the lookup that produced its text, so the overlay can preview an edit
    # exactly as I18n would render it: the interpolation values (strings, integers and booleans as they are,
    # everything else as its `to_s`; a value that is itself a marked message is `{"$marked": clean text}`),
    # and `__n`, `__form` for a plural lookup and `__html` for an `_html` key.
    module Args
      RESERVED = %i[scope default separator resolve object fallback fallback_in_progress fallback_original_locale
        format cascade throw raise deep_interpolation exception_handler locale].freeze

      module_function

      def json(options, extras = {})
        recorded = {}
        options.each do |name, value|
          next if RESERVED.include?(name) || value.is_a?(Hash) || value.is_a?(Array) || value.is_a?(Proc)

          recorded[name.to_s] = value(value)
        end
        extras.each { |name, value| recorded[name.to_s] = value }
        JSON.generate(recorded)
      end

      def value(value)
        case value
        when String then Marker.marked?(value) ? {"$marked" => Marker.strip(value)} : value.to_s
        when Integer, true, false then value
        when nil then ""
        else value.to_s
        end
      end
    end
  end
end
