require "open3"

module DialectoRails
  module Scan
    # Reads a repository through `git`, with an argument array (no shell). The scanner reads the committed
    # state at a sha, never the working tree, because that is what pull requests are made against.
    class Git
      Entry = Struct.new(:path, :blob, :size, keyword_init: true)

      TIMEOUT = 30

      def initialize(root = Dir.pwd)
        @root = root
      end

      def repository?
        run("rev-parse", "--is-inside-work-tree", chomp: true) == "true"
      rescue ConfigError
        false
      end

      def head_sha = run("rev-parse", "HEAD", chomp: true)

      # The current branch name, or nil on a detached HEAD.
      def branch
        name = run("rev-parse", "--abbrev-ref", "HEAD", chomp: true)
        name == "HEAD" ? nil : name
      end

      # The remote's default branch, or nil when `origin/HEAD` isn't set.
      def default_branch
        ref = run("symbolic-ref", "--short", "refs/remotes/origin/HEAD", chomp: true, allow_failure: true)
        ref&.sub(%r{\Aorigin/}, "")
      end

      def remote_url = run("remote", "get-url", "origin", chomp: true, allow_failure: true)

      # Every blob under `sha`: path, blob id and size. Symlinks and submodules are left out.
      def entries(sha)
        raw = run("ls-tree", "-r", "-z", "-l", sha)
        raw.split("\0").filter_map do |line|
          meta, path = line.split("\t", 2)
          mode, type, blob, size = meta.split(" ")
          next unless type == "blob" && mode != "120000" && path

          Entry.new(path: path.dup.force_encoding(Encoding::UTF_8), blob: blob, size: size.to_i)
        end
      end

      def blob(id) = run("cat-file", "blob", id)

      private

      def run(*args, chomp: false, allow_failure: false)
        out, err, status = Open3.capture3("git", "-C", @root, *args, binmode: true)
        unless status.success?
          return nil if allow_failure

          raise ConfigError, "git #{args.first} failed: #{err.to_s.strip.lines.first.to_s.strip}"
        end

        chomp ? out.strip : out
      rescue Errno::ENOENT
        raise ConfigError, "git isn't installed or isn't on the PATH"
      end
    end
  end
end
