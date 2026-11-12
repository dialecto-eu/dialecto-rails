module DialectoRails
  module Scan
    # Which files are catalogs: the project's catalog paths, matched the way Dialecto matches them
    # (ADR-0020): `**` spans folders, `*` stays in one folder or file name, `?` is one character, and no
    # wildcard reaches a folder or file whose name starts with a dot.
    class Catalogs
      def initialize(patterns)
        @patterns = patterns.map { |pattern| pattern.split("/") }
      end

      def match?(path)
        segments = path.split("/")
        @patterns.any? { |pattern| match_segments?(pattern, segments) }
      end

      private

      def match_segments?(pattern, path)
        return path.empty? if pattern.empty?

        head, *rest = pattern
        if head == "**"
          (0..path.length).any? do |taken|
            path.first(taken).none? { |segment| segment.start_with?(".") } &&
              match_segments?(rest, path.drop(taken))
          end
        else
          !path.empty? && match_segment?(head, path.first) && match_segments?(rest, path.drop(1))
        end
      end

      def match_segment?(pattern, segment)
        return false if segment.start_with?(".") && pattern.start_with?("*", "?")

        regex = pattern.each_char.map do |char|
          case char
          when "*" then "[^/]*"
          when "?" then "[^/]"
          else Regexp.escape(char)
          end
        end.join
        Regexp.new("\\A#{regex}\\z").match?(segment)
      end
    end
  end
end
