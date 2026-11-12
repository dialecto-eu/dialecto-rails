require "fileutils"
require "open3"
require "tmpdir"

# A throwaway git repository built with the `git` binary, for tests that read committed state.
class GitFixture
  attr_reader :root

  def initialize(files = {}, **options)
    branch = options.delete(:branch) || "main"
    files = files.merge(options) # Ruby reads a brace-less `"path" => content` hash as keywords
    @root = Dir.mktmpdir("dialecto-rails-test")
    git("init", "-q", "-b", branch)
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "Test")
    git("config", "commit.gpgsign", "false")
    commit(files) unless files.empty?
  end

  def write(path, content)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
  end

  def commit(files = {}, **options)
    message = options.delete(:message) || "commit"
    files = files.merge(options)
    files.each { |path, content| write(path, content) }
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  def checkout(branch, create: false)
    create ? git("checkout", "-q", "-b", branch) : git("checkout", "-q", branch)
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", root, *args)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out
  end

  def cleanup = FileUtils.remove_entry(root)
end
