require "uri"
require "open3"
require_relative "../version"

module DialectoRails
  module InContext
    # The site's context for the sidebar (spec-0016 §4, served at `/__dialecto/context`): `{repo, project,
    # branch, sha, dirty, addon}`, read from git on demand so switching branches needs no restart. A git
    # failure only leaves its field empty. Argument arrays, no shell; each call has a 5 s timeout.
    class GitContext
      SEGMENT = /\A[A-Za-z0-9._-]+\z/
      SHA = /\A[0-9a-f]{40}\z/
      MAX_DIRTY = 200
      TIMEOUT = 5
      CACHE_SECONDS = 1.0

      def initialize(root:, project: nil, catalogs: "config/locales",
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @root = root.to_s
        @project = project
        @catalogs = catalogs
        @clock = clock
        @mutex = Mutex.new
        @cached = nil
        @cached_at = nil
      end

      def read
        @mutex.synchronize do
          now = @clock.call
          return @cached if @cached && now - @cached_at < CACHE_SECONDS

          @cached_at = now
          @cached = build
        end
      end

      def self.parse_github_remote(remote)
        remote = remote.to_s.strip
        host, path =
          if remote.include?("://")
            uri = URI.parse(remote) rescue nil
            [uri&.host, uri&.path] if uri && %w[http https ssh git].include?(uri.scheme)
          elsif (match = remote.match(%r{\A[^@\s/:]+@([^:/\s]+):(.+)\z}))
            [match[1], match[2]]
          end
        return nil unless host && path && host.downcase == "github.com"

        segments = path.delete_prefix("/").chomp("/").delete_suffix(".git").split("/")
        segments.length == 2 && segments.all? { |segment| segment.match?(SEGMENT) } ? segments.join("/") : nil
      end

      # Repo-root-relative paths (sorted, unique, capped) from `git status --porcelain=v1 -z`.
      def self.parse_porcelain_z(output)
        fields = output.to_s.split("\0")
        paths = []
        until fields.empty?
          field = fields.shift
          match = field.match(/\A(.)(.) (.+)\z/m)
          next unless match

          paths << match[3]
          renamed = "RC".include?(match[1]) || "RC".include?(match[2])
          original = renamed ? fields.shift : nil
          paths << original if original && !original.empty?
        end
        paths.uniq.sort.first(MAX_DIRTY)
      end

      private

      def build
        branch = git("rev-parse", "--abbrev-ref", "HEAD").to_s.strip
        sha = git("rev-parse", "HEAD").to_s.strip
        {
          repo: self.class.parse_github_remote(git("remote", "get-url", "origin")),
          project: @project,
          branch: ["", "HEAD"].include?(branch) ? nil : branch,
          sha: sha.match?(SHA) ? sha : nil,
          dirty: self.class.parse_porcelain_z(git("status", "--porcelain=v1", "-z", "--untracked-files=all", "--",
            File.expand_path(@catalogs, @root))),
          addon: "rails@#{DialectoRails::VERSION}"
        }
      end

      def git(*args)
        Open3.popen3("git", "-C", @root, *args) do |stdin, stdout, stderr, waiter|
          stdin.close
          stdout.binmode
          reader = Thread.new { stdout.read }
          Thread.new { stderr.read }
          unless waiter.join(TIMEOUT)
            Process.kill("KILL", waiter.pid) rescue nil
            return nil
          end
          waiter.value.success? ? reader.value.force_encoding(Encoding::UTF_8) : nil
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
