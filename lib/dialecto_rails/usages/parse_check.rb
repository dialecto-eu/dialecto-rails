require "prism"
require_relative "scanner"
require_relative "templates"

module DialectoRails
  module Usages
    # `dialecto-rails parse-check`: do these files still parse with the gem's own readers? Ruby goes through Prism;
    # ERB and HAML through the same extractors the usage scan uses, and the Ruby they yield through Prism, with the
    # constructs a template may hold outside a method tolerated as the scan tolerates them. A rewritten call site
    # must keep every file readable, so the rename check runs this over the bytes it would commit.
    class ParseCheck
      Failure = Struct.new(:path, :line, :message, keyword_init: true)

      RUBY_NAMES = %w[Rakefile Gemfile].freeze

      # `{checked: n, skipped: n, failures: [Failure]}`; a file of a kind the scan doesn't read is skipped.
      def self.call(files) = new(files).call

      def initialize(files)
        @files = files
      end

      def call
        result = {checked: 0, skipped: 0, failures: []}
        @files.each do |path, bytes|
          failure = check(path, bytes.dup.force_encoding(Encoding::UTF_8), result)
          result[:failures] << failure if failure
        end
        result
      end

      private

      def check(path, bytes, result)
        lang = language(path)
        return skip(result) unless lang

        ruby = reduce(lang, bytes)
        return skip(result) if ruby.nil?

        result[:checked] += 1
        errors = Prism.parse(ruby, version: "latest").errors
        errors = errors.reject { |error| Scanner::TEMPLATE_TOLERATED.include?(error.message) } unless lang == :ruby
        return if errors.empty?

        Failure.new(path: path, line: errors.first.location.start_line, message: errors.first.message)
      rescue => e
        # A parser's message may quote the source; only the class and our own line-number messages are kept.
        message = e.is_a?(Templates::Unreadable) ? e.message : "#{e.class.name} while reading the file"
        Failure.new(path: path, line: nil, message: message)
      end

      def skip(result)
        result[:skipped] += 1
        nil
      end

      def reduce(lang, bytes)
        case lang
        when :ruby then bytes
        when :erb then Templates.erb(bytes)
        when :haml then Templates.haml(bytes)
        end
      end

      def language(path)
        extension = File.extname(path).downcase
        return :ruby if Scanner::RUBY_EXTENSIONS.include?(extension) || RUBY_NAMES.include?(File.basename(path))
        return :erb if extension == ".erb"

        :haml if extension == ".haml"
      end
    end
  end
end
