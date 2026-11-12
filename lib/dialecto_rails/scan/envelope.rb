require "digest"
require "json"

module DialectoRails
  module Scan
    # The scan request body (docs/ingestion-api.md): the committed catalog files verbatim, the commit
    # and branch they were read at, and a checksum that makes a re-run a no-op.
    class Envelope
      MB = 1024 * 1024
      MAX_FILES = 1_000
      MAX_FILE_BYTES = 5 * MB
      MAX_CATALOG_BYTES = 10 * MB
      MAX_BODY_BYTES = 20 * MB

      attr_reader :payload, :files

      # `usages` is the usage scan's envelope (a Hash) or nil.
      def self.build(git:, catalogs:, sha:, branch:, usages: nil)
        new(git, catalogs, sha, branch, usages).tap(&:validate!)
      end

      def initialize(git, catalogs, sha, branch, usages)
        @git = git
        @sha = sha
        @branch = branch
        @usages = usages
        @files = git.entries(sha).select { |entry| catalogs.match?(entry.path) }.sort_by(&:path)
      end

      def validate!
        raise ConfigError, no_files_message if files.empty?
        check_limits!
        @payload = build_payload
        body = JSON.generate(@payload)
        return if body.bytesize <= MAX_BODY_BYTES

        raise ConfigError, "The scan is #{format_mb(body.bytesize)} MB; Dialecto takes #{MAX_BODY_BYTES / MB} MB. " \
                           "Narrow DIALECTO_CATALOG_PATHS, or send fewer usage records."
      end

      def body = JSON.generate(payload)

      def counts = {files: files.length, records: @usages ? @usages["usages"].length : nil}

      private

      def build_payload
        templates = files.map do |entry|
          content = @git.blob(entry.blob).force_encoding(Encoding::UTF_8)
          unless content.valid_encoding?
            raise ConfigError, "#{entry.path} isn't valid UTF-8, so it can't be sent as text. Dialecto " \
                               "reads UTF-8 catalogs: re-save the file as UTF-8 or leave it out of DIALECTO_CATALOG_PATHS."
          end
          {path: entry.path, content: content}
        end

        payload = {gitSha: @sha, gitBranch: @branch, checksum: checksum, templates: templates}
        payload[:railsUsages] = @usages if @usages
        payload
      end

      def check_limits!
        if files.length > MAX_FILES
          raise ConfigError, "#{delimit(files.length)} catalog files match; Dialecto takes #{delimit(MAX_FILES)}. " \
                             "Narrow DIALECTO_CATALOG_PATHS (for example to the source locale and the languages you translate)."
        end

        big = files.find { |entry| entry.size > MAX_FILE_BYTES }
        if big
          raise ConfigError, "#{big.path} is #{format_mb(big.size)} MB; Dialecto takes #{MAX_FILE_BYTES / MB} MB a file."
        end

        total = files.sum(&:size)
        return if total <= MAX_CATALOG_BYTES

        raise ConfigError, "The catalogs are #{format_mb(total)} MB; Dialecto takes #{MAX_CATALOG_BYTES / MB} MB. " \
                           "Narrow DIALECTO_CATALOG_PATHS."
      end

      # The commit, the branch and each sent file's blob id, plus the usage records, so a code-only change
      # with unchanged catalogs is a new scan, a re-run is a no-op and a revert is a new scan.
      def checksum
        digest = Digest::SHA256.new
        digest << "dialecto-rails/1\n#{@sha}\n#{@branch}\n"
        files.each { |entry| digest << "#{@git.respond_to?(:blob_id) ? @git.blob_id(entry.blob) : entry.blob} #{entry.path}\n" }
        digest << "usages:#{Digest::SHA256.hexdigest(JSON.generate(@usages))}\n" if @usages
        digest.hexdigest
      end

      def no_files_message
        "No file at #{@sha[0, 8]} matches the catalog paths. Dialecto reads the files your project's " \
          "settings name; set DIALECTO_CATALOG_PATHS to match them (default config/locales/**/*.yml)."
      end

      def format_mb(bytes) = format("%.1f", bytes.to_f / MB)

      def delimit(number) = number.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end
  end
end
