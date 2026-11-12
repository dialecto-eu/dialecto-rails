module DialectoRails
  module Usages
    # A literal in the source that carries part of a key: where its text sits (absolute UTF-8 byte
    # offsets), what delimits it, and where an anchor that contains it must reach (`anchor_end`).
    Literal = Struct.new(:text_start, :text_end, :delim, :role, :head, :anchor_end, keyword_init: true) do
      def head? = head == true
    end

    # Pattern parts (spec-0018 §3): `{lit: String}` and `{wild: true}`, adjacent ones merged.
    module Parts
      module_function

      def build(items)
        merged = []
        items.each do |item|
          if item[:wild]
            merged << {wild: true} unless merged.last&.key?(:wild)
          elsif !item[:lit].to_s.empty?
            if merged.last&.key?(:lit)
              merged[-1] = {lit: merged.last[:lit] + item[:lit]}
            else
              merged << {lit: item[:lit]}
            end
          end
        end
        collapse(merged)
      end

      # `*` `.` `*` can only read what `*` reads: an unknown scope in front of an unknown key.
      def collapse(parts)
        index = 0
        while index <= parts.length - 3
          if parts[index][:wild] && parts[index + 1] == {lit: "."} && parts[index + 2][:wild]
            parts.slice!(index + 1, 2)
          else
            index += 1
          end
        end
        parts
      end

      def pattern(parts) = parts.map { |part| part[:lit] || "*" }.join

      def json(parts) = parts.map { |part| part[:wild] ? {"wild" => true} : {"lit" => part[:lit]} }
    end

    # Byte offset → 1-based line, for one file.
    class LineIndex
      def initialize(bytes)
        @newlines = []
        offset = -1
        @newlines << offset while (offset = bytes.byteindex("\n", offset + 1))
      end

      def line(offset) = @newlines.bsearch_index { |position| position >= offset } || @newlines.length

      def line_of(offset) = line(offset) + 1
    end

    # The key-bearing literals of one record, turned into the contract's `spans` and the anchor around them.
    class Anchor
      MAX_BYTES = 2_000

      attr_reader :start, :finish, :literals

      def initialize(start:, call_end:, literals:, extra_end: nil)
        @start = start
        @literals = literals.sort_by(&:text_start)
        ends = @literals.map(&:anchor_end)
        ends << extra_end if extra_end
        @finish = ends.empty? ? call_end : ends.max
      end

      def too_long? = finish - start > MAX_BYTES

      def index_of(literal) = literals.index { |candidate| candidate.equal?(literal) }

      def spans
        literals.map do |literal|
          span = {"start" => literal.text_start - start, "end" => literal.text_end - start, "delim" => literal.delim,
                  "role" => literal.role.to_s, "lang" => "ruby"}
          if literal.head?
            span["head"] = true
            span["closed"] = false
          end
          span
        end
      end
    end
  end
end
