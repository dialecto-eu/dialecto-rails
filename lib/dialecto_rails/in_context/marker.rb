require "json"

module DialectoRails
  module InContext
    # The in-context marker codec v1 (spec-0016 §3), byte-identical to the overlay's `codec.js`, the Astro
    # add-on's encoder and `DialectoInContext.Marker`: `OPEN + header + HEADER_END + text + CLOSE`, where
    # the header is the UTF-8 payload `domain US key US locale` (optionally `RS argsJSON`) with each byte
    # written as four base-4 digits, most significant first. Every marker codepoint is Default_Ignorable, so
    # the text renders unchanged. The codepoints are written by number, never as literal invisible characters.
    module Marker
      OPEN = [0x2062].pack("U").freeze
      HEADER_END = [0x2063].pack("U").freeze
      CLOSE = [0x2064].pack("U").freeze
      DIGITS = [0x200C, 0x200D, 0x2060, 0x2061].map { |code| [code].pack("U").freeze }.freeze
      FIELD_SEP = "\u001F".freeze
      RECORD_SEP = "\u001E".freeze

      DIGIT_VALUES = DIGITS.each_with_index.to_h.freeze
      Segment = Struct.new(:domain, :key, :locale, :args, :text, :open, keyword_init: true)

      module_function

      # Everything that precedes the marked text: OPEN, the header digits, HEADER_END.
      def prefix(domain, key, locale, args_json = nil)
        identity = [domain, key, locale].join(FIELD_SEP)
        payload = args_json ? identity + RECORD_SEP + args_json : identity
        digits = payload.b.each_byte.flat_map { |byte| [byte >> 6, (byte >> 4) & 3, (byte >> 2) & 3, byte & 3] }
        OPEN + digits.map { |digit| DIGITS[digit] }.join + HEADER_END
      end

      def mark(domain, key, locale, text, args_json = nil)
        prefix(domain, key, locale, args_json) + text + CLOSE
      end

      def marked?(text) = text.is_a?(String) && text.include?(OPEN)

      # `text` without markers. Digit codepoints outside a header (a real ZWJ in an emoji) are kept.
      def strip(text)
        return text unless text.include?(OPEN) || text.include?(HEADER_END) || text.include?(CLOSE)

        chars = text.chars
        out = +""
        index = 0
        while index < chars.length
          char = chars[index]
          if char == OPEN && (header = read_header(chars, index + 1))
            index = header[:next]
          elsif char == OPEN || char == HEADER_END || char == CLOSE
            index += 1
          else
            out << char
            index += 1
          end
        end
        out
      end

      # Every well-formed marked segment, outer before inner, with its clean text. Malformed headers and
      # unbalanced CLOSEs are ignored; an OPEN never closed extends to the end and is flagged `open`.
      def parse(text)
        chars = text.chars
        done = []
        stack = []
        index = 0
        while index < chars.length
          char = chars[index]
          if char == OPEN && (header = read_header(chars, index + 1))
            stack << {header: header, order: index, text: +""}
            index = header[:next]
          elsif char == CLOSE && !stack.empty?
            done << segment(stack.pop, false)
            index += 1
          else
            stack.each { |open| open[:text] << char } unless char == HEADER_END
            index += 1
          end
        end
        (done + stack.reverse.map { |open| segment(open, true) }).sort_by { |entry| entry[:order] }.map { |entry| entry[:segment] }
      end

      def segment(open, unclosed)
        identity, _sep, args = open[:header][:payload].partition(RECORD_SEP)
        domain, key, locale = identity.split(FIELD_SEP, 3)
        parsed = args.empty? ? nil : (JSON.parse(args) rescue nil)
        {order: open[:order],
         segment: Segment.new(domain: domain, key: key, locale: locale, args: parsed, text: strip(open[:text]),
           open: unclosed)}
      end

      # The header after an OPEN at `from`: digits up to HEADER_END, a multiple of four of them.
      def read_header(chars, from)
        digits = []
        index = from
        while index < chars.length && (value = DIGIT_VALUES[chars[index]])
          digits << value
          index += 1
        end
        return nil unless chars[index] == HEADER_END && (digits.length % 4).zero?

        bytes = digits.each_slice(4).map { |a, b, c, d| (a << 6) | (b << 4) | (c << 2) | d }
        payload = bytes.pack("C*").force_encoding(Encoding::UTF_8)
        payload.valid_encoding? ? {payload: payload, next: index + 1} : nil
      end
    end
  end
end
