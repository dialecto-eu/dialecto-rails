require "haml"
require_relative "templates"

module DialectoRails
  module Usages
    # Reduces a HAML template to the Ruby inside it, byte for byte where it was (spec-0023 §6.2): everything
    # that isn't Ruby becomes a space, each piece of Ruby is written back at its own offset, and the `end`s the
    # indentation implied are appended after the last byte, so no offset moves. The scan doesn't follow control
    # flow, so `else`, `when` and `rescue` (which would need an `end` in the middle of the file) are left out and
    # the branches simply follow one another; `case` loses its keyword for the same reason. The pieces come from
    # `Haml::Parser`'s tree; where they sit comes from the source lines.
    #
    # Read: `= code`, `- code`, `%tag= code`, `%tag{attributes}`, `#{interpolation}` in text, and `:ruby` filters.
    # A construct whose Ruby can't be put back in place raises `Unreadable`, and the file is reported unscanned.
    class HamlExtractor
      Unreadable = Templates::Unreadable

      MID_BLOCK = %w[else elsif when in rescue ensure].freeze

      def self.extract(bytes)
        new(bytes).call
      end

      def initialize(bytes)
        @source = bytes.b
        @lines = []
        position = 0
        @source.each_line do |line|
          @lines << position
          position += line.bytesize
        end
        @out = @source.gsub(/[^\n]/n, " ")
        @used = Hash.new(0)
        @opens = 0
        @last_end = 0
      end

      def call
        root = Haml::Parser.new({}).call(@source.dup.force_encoding(Encoding::UTF_8))
        walk(root)
        (@out << "\n" << ("end\n" * @opens)).force_encoding(Encoding::UTF_8)
      rescue Haml::SyntaxError => e
        raise Unreadable, "HAML syntax error#{" on line #{e.line + 1}" if e.respond_to?(:line) && e.line}"
      end

      private

      def walk(node)
        node.children.each do |child|
          visit(child)
          walk(child)
        end
      end

      def script?(node) = %i[script silent_script].include?(node.type)

      def mid_block?(node) = script?(node) && MID_BLOCK.include?(node.value[:keyword].to_s)

      # A node whose Ruby opens a block that needs an `end` (`case` is written without its keyword).
      def opens_block?(node)
        script?(node) && !node.children.empty? && !mid_block?(node) && node.value[:keyword].to_s != "case"
      end

      def visit(node)
        value = node.value
        case node.type
        when :script, :silent_script then code(node, value[:text])
        when :tag then tag(node, value)
        when :plain then interpolations(node.line)
        when :filter then ruby_filter(node, value) if value[:name] == "ruby"
        end
        @opens += 1 if opens_block?(node)
      end

      def tag(node, value)
        line = node.line
        attributes = value[:dynamic_attributes]
        line = attribute_hash(line) if attributes&.old
        return unless value[:parse] && value[:value]

        found = locate(line, value[:value].b)
        if found
          write(found, value[:value])
        else
          interpolations(line)
        end
      end

      # `%tag{ … }`: the hash as written, from its `{` to the matching `}` (it may span lines). Returns the line
      # the hash ends on.
      def attribute_hash(line)
        text = line_text(line).b
        open = text.index("{", @used[line])
        raise Unreadable, "HAML attributes on line #{line} can't be placed in the source" unless open

        start = @lines[line - 1] + open
        close = matching_brace(@source, start + 1)
        raise Unreadable, "HAML attributes on line #{line} aren't closed" unless close

        # As an array literal: `[ a: 1 ]` and `[ attributes ]` both read as Ruby, which a `{ … }` statement doesn't.
        region = @source.byteslice(start, close - start + 1)
        region.setbyte(0, 91)
        region.setbyte(-1, 93)
        write(start, region)
        last = line_of(close)
        @used[last] = close - @lines[last - 1] + 1
        last
      end

      def code(node, text)
        text = text.to_s.strip
        return if text.empty?

        line = node.line
        keyword = node.value[:keyword].to_s
        return code_after_keyword(line, text, keyword) if %w[elsif case].include?(keyword)
        return if MID_BLOCK.include?(keyword)

        found = locate(line, text.b)
        if found
          write(found, text)
        elsif text.start_with?('"') && text.include?("\#{")
          interpolations(line) # a text line HAML turned into a quoted string
        else
          multiline(line, text)
        end
      end

      # `elsif cond` and `case value` keep what follows the keyword; the keyword's bytes stay blank.
      def code_after_keyword(line, text, keyword)
        rest = text.sub(/\A#{keyword}\s*/, "")
        return if rest.empty?

        found = locate(line, rest.b)
        raise Unreadable, "HAML code on line #{line} can't be placed in the source" unless found

        write(found, rest)
      end

      # Code that spans lines is read by HAML as one line with single spaces between the parts; each part is
      # put back on its own line.
      def multiline(first_line, text)
        word = text[/\S+/].to_s.b
        first = line_text(first_line).b
        at = first.index(word, @used[first_line])
        raise Unreadable, "HAML code on line #{first_line} can't be placed in the source" unless at

        index = first_line
        loop do
          raw = line_text(index).b
          continues = raw.rstrip.end_with?(",") || raw.match?(/\s\|\s*\z/n)
          piece = raw.strip.sub(/\s+\|\z/n, "")
          if index == first_line
            piece = raw.byteslice(at..).strip.sub(/\s+\|\z/n, "")
            offset = @lines[index - 1] + at
          else
            offset = @lines[index - 1] + raw.index(piece)
          end
          write(offset, piece, terminate: !continues)
          @used[index] = offset - @lines[index - 1] + piece.bytesize
          break unless continues && index < @lines.length

          index += 1
        end
      end

      def interpolations(line_number)
        line = line_text(line_number).b
        position = 0
        while (open = line.index("\#{", position))
          close = matching_brace(line, open + 2)
          break unless close

          inner = line.byteslice(open + 2, close - open - 2)
          absolute = @lines[line_number - 1] + open + 2
          @out[absolute - 1] = ";" if absolute.positive?
          @out[absolute, inner.bytesize] = inner
          @last_end = absolute + inner.bytesize
          position = close + 1
        end
      end

      def matching_brace(text, from)
        depth = 1
        quote = nil
        index = from
        while index < text.bytesize
          char = text.getbyte(index).chr
          if quote
            index += 1 if char == "\\"
            quote = nil if char == quote
          elsif ['"', "'"].include?(char) then quote = char
          elsif char == "{" then depth += 1
          elsif char == "}"
            depth -= 1
            return index if depth.zero?
          end
          index += 1
        end
        nil
      end

      def ruby_filter(node, value)
        index = node.line + 1
        value[:text].to_s.each_line do |text|
          stripped = text.strip
          next if stripped.empty?

          index += 1 while index <= @lines.length && !line_text(index).include?(stripped)
          raise Unreadable, ":ruby filter on line #{node.line} can't be placed in the source" if index > @lines.length

          write(locate(index, stripped.b), stripped)
        end
      end

      # The byte offset of `text` in a source line, searching from the end of what was already placed there.
      def locate(line_number, text, from: nil)
        return nil if line_number < 1 || line_number > @lines.length

        line = line_text(line_number).b
        at = line.index(text, from || @used[line_number])
        return nil unless at

        @used[line_number] = at + text.bytesize
        @lines[line_number - 1] + at
      end

      CONTINUES = /(?:[,(\[{\\.]|&&|\|\||\+|-|\*|\?|:(?!:)\s*)\z/

      def write(offset, text, terminate: true)
        text = text.b
        @out[offset - 1] = ";" if offset.positive? && @out.getbyte(offset - 1) == 32 && separate?(offset)
        @out[offset, text.bytesize] = text
        @last_end = offset + text.bytesize
        # HAML reads each line on its own; Ruby would let `render "x", f:` swallow the next line.
        open_ended = text.match?(CONTINUES) && !text.match?(/\w:\z/)
        return if !terminate || open_ended

        following = @out.getbyte(@last_end)
        # A newline already ends a statement; it is replaced only after `f:`, which would take the next line as
        # its value (and never after a piece that may hold a `#` comment, which would swallow what follows).
        @out[@last_end] = ";" if following == 32 || (following == 10 && text.match?(/\w:\z/))
      end

      # A `;` goes before a piece when another piece already stands earlier on the same line.
      def separate?(offset)
        start = @out.rindex("\n", offset - 1) || -1
        @out.byteslice(start + 1, offset - start - 1).match?(/\S/)
      end

      def line_of(offset) = (@lines.rindex { |start| start <= offset } || 0) + 1

      def line_text(number)
        from = @lines[number - 1]
        to = @lines[number] || @source.bytesize
        @source.byteslice(from, to - from).chomp
      end
    end
  end
end
