require "json"
require "optparse"
require_relative "../errors"
require_relative "../config"
require_relative "git"
require_relative "worktree"
require_relative "catalogs"
require_relative "envelope"
require_relative "client"

module DialectoRails
  module Scan
    # `dialecto-rails scan | usages | check | doctor | version`.
    # `run` returns the exit code: 0 ok, 1 findings, 2 can't start, 3 refused, 4 retryable.
    class Cli
      COMMANDS = %w[scan doctor version help].freeze
      TOKEN_SHAPE = /\Adlk_[A-Za-z0-9_-]{43}\z/

      def self.run(argv, env: ENV, out: $stdout, err: $stderr, root: Dir.pwd, client: nil, input: $stdin)
        new(argv, env: env, out: out, err: err, root: root, client: client, input: input).run
      end

      def initialize(argv, env:, out:, err:, root:, client: nil, input: $stdin)
        @argv = argv.dup
        @env = env
        @out = out
        @err = err
        @in = input
        @root = root
        @client_factory = client || ->(config) { Client.new(config, log: ->(line) { @err.puts(line) }) }
        @flags = {}
      end

      def run
        command = @argv.shift || "help"
        case command
        when "scan" then scan
        when "doctor" then doctor
        when "usages" then usages
        when "check" then check
        when "parse-check" then parse_check
        when "version", "--version" then @out.puts("dialecto-rails #{VERSION}") || 0
        when "help", "--help", "-h" then help
        else
          @err.puts("Unknown command #{command.inspect}.")
          help(@err)
          2
        end
      rescue Error => e
        @err.puts(e.message)
        @err.puts(e.backtrace.first(8)) if @flags[:debug]
        e.exit_code
      end

      private

      def help(io = @out)
        io.puts <<~HELP
          dialecto-rails #{VERSION}

            dialecto-rails scan [--branch NAME] [--sha SHA] [--usages] [--require-usages] [--worktree] [--dry-run] [--debug]
            dialecto-rails usages [--summary] [--sha SHA] [--worktree] [--out FILE]
            dialecto-rails check [--sha SHA] [--worktree]
            dialecto-rails parse-check [--root DIR]   (relative paths on standard input)
            dialecto-rails doctor
            dialecto-rails version

          Settings come from the environment: DIALECTO_SCAN_TOKEN, DIALECTO_PROJECT (the project's number),
          DIALECTO_URL, DIALECTO_CATALOG_PATHS, DIALECTO_USAGES, DIALECTO_DEFAULT_BRANCH.
        HELP
        0
      end

      def parse_flags
        OptionParser.new do |opts|
          opts.on("--branch NAME") { |value| @flags[:branch] = value }
          opts.on("--sha SHA") { |value| @flags[:sha] = value }
          opts.on("--usages") { @flags[:usages] = true }
          opts.on("--require-usages") { @flags[:require_usages] = true }
          opts.on("--worktree") { @flags[:worktree] = true }
          opts.on("--root DIR") { |value| @flags[:root] = value }
          opts.on("--summary") { @flags[:summary] = true }
          opts.on("--out FILE") { |value| @flags[:out] = value }
          opts.on("--dry-run") { @flags[:dry_run] = true }
          opts.on("--debug") { @flags[:debug] = true }
        end.parse!(@argv)
      rescue OptionParser::ParseError => e
        raise ConfigError, e.message
      end

      def config
        @config ||= Config.new({usages: (true if @flags[:usages])}.compact, @env)
      end

      ## scan

      def scan
        parse_flags
        require_settings!
        git = Git.new(@root)
        raise ConfigError, "#{@root} isn't inside a git repository." unless git.repository?

        sha = @flags[:sha] || git.head_sha
        branch = @flags[:branch] || current_branch(git)
        client = @client_factory.call(config)

        unless @flags[:dry_run] || scanned_branch?(client, git, branch)
          @out.puts("Dialecto doesn't scan the branch #{branch}; nothing sent.")
          write_outputs("outcome" => "skipped")
          return 0
        end

        # `--worktree` reads the folder as it is, dirty files included: a testing escape hatch, never what a PR is made from.
        reader = @flags[:worktree] ? Worktree.new(@root) : git
        @err.puts("Reading the working tree, not commit #{sha[0, 8]}: a pull request from this scan would carry these bytes.") if @flags[:worktree]
        usages = usage_scan(reader, sha)
        envelope = Envelope.build(git: reader, catalogs: Catalogs.new(config.catalog_paths), sha: sha, branch: branch,
          usages: usages)

        if @flags[:dry_run]
          counts = envelope.counts
          @out.puts("Dry run: #{counts[:files]} catalog files at #{sha[0, 8]} on #{branch}" \
                    "#{counts[:records] ? ", #{counts[:records]} usage records" : ""}; nothing sent.")
          return 0
        end

        report(client.post_scan(envelope.body))
        write_outputs("files" => envelope.counts[:files], "records" => envelope.counts[:records])
        0
      end

      # GitHub Actions step outputs, when the runner offers the file. Values come partly from the
      # server's answer, so only a plain word is written: a newline would add outputs of its own.
      def write_outputs(values)
        path = @env["GITHUB_OUTPUT"].to_s
        return if path.empty?

        File.open(path, "a") do |file|
          values.each { |name, value| file.puts("#{name}=#{value}") if value.to_s.match?(/\A[\w.-]+\z/) }
        end
      end

      def require_settings!
        raise ConfigError, "Set DIALECTO_SCAN_TOKEN to the project's scan token (Settings → Scan token)." unless config.scan_token
        unless config.project&.match?(/\A\d+\z/)
          raise ConfigError, "Set DIALECTO_PROJECT to the project's number, the <number> in its Dialecto " \
                             "URL /repos/<number>#{config.project ? " (got #{config.project.inspect})" : ""}."
        end
        problem = config.url_problem
        raise ConfigError, problem if problem
      end

      def current_branch(git)
        head_ref = @env["GITHUB_HEAD_REF"].to_s
        return head_ref unless head_ref.empty?

        ref = @env["GITHUB_REF_NAME"].to_s
        return ref if @env["GITHUB_REF_TYPE"] == "branch" && !ref.empty?

        git.branch || raise(ConfigError, "HEAD is detached: pass --branch NAME.")
      end

      # The default branch is always scanned; others when the scan mode is `all`, they are tracked, or they
      # match the project's regex (the rule of the generated workflow and `Branches.scans_branch?`).
      def scanned_branch?(client, git, branch)
        default = config.default_branch || git.default_branch
        return true if branch == default

        settings = client.scan_config
        return true if settings["scan_mode"] == "all"
        return true if Array(settings["tracked_branches"]).include?(branch)

        regex = settings["branch_regex"].to_s
        return true if !regex.empty? && Regexp.new(regex).match?(branch)

        # Without a known default branch a refusal here would skip the branch that matters most.
        default.nil?
      rescue RegexpError
        false
      end

      ## usages and check

      # Runs the usage scan for these two commands, which need no token and send nothing.
      # `--worktree` reads the folder as it is, which needs no git repository.
      def local_scan
        parse_flags
        reader, sha = scan_source

        begin
          require_relative "../usages/scanner"
        rescue LoadError => e
          raise ConfigError, "The usage scan needs the prism gem (#{e.message.lines.first.to_s.strip}); gem install prism."
        end
        scanner = DialectoRails::Usages::Scanner.new(git: reader, sha: sha, config: config)
        [scanner.call, scanner.catalog]
      end

      def scan_source
        return [Worktree.new(@root), @flags[:sha] || "worktree"] if @flags[:worktree]

        git = Git.new(@root)
        raise ConfigError, "#{@root} isn't inside a git repository." unless git.repository?

        [git, @flags[:sha] || git.head_sha]
      end

      ## parse-check

      # Reads relative paths, one per line, from standard input and checks that each still parses with the gem's
      # own readers (`--root DIR`, default the current folder). For the rename check; it sends nothing.
      def parse_check
        parse_flags
        begin
          require_relative "../usages/parse_check"
        rescue LoadError => e
          raise ConfigError, "The parse check needs the prism gem (#{e.message.lines.first.to_s.strip}); gem install prism."
        end
        root = @flags[:root] || @root
        files = @in.each_line.map(&:chomp).reject(&:empty?).map { |path| [path, File.binread(File.join(root, path))] }
        result = DialectoRails::Usages::ParseCheck.call(files)
        result[:failures].each { |failure| @out.puts("FAIL #{failure.path}:#{failure.line} #{failure.message}") }
        @out.puts("checked #{result[:checked]}, skipped #{result[:skipped]}, failed #{result[:failures].length}")
        result[:failures].empty? ? 0 : 1
      end

      def usages
        require_relative "../usages/summary"
        envelope, catalog = local_scan
        @out.puts(DialectoRails::Usages::Summary.new(envelope, catalog.keys.to_a).render)
        File.write(@flags[:out], JSON.pretty_generate(envelope)) if @flags[:out]
        0
      end

      def check
        require_relative "../usages/check"
        envelope, catalog = local_scan
        check = DialectoRails::Usages::Check.new(envelope, catalog)
        check.findings.each do |finding|
          @out.puts("#{finding.warning ? "warning" : "error"} #{finding.file}:#{finding.line} #{finding.code}: #{finding.message}")
        end
        @out.puts("No findings.") if check.findings.empty?
        check.failed? ? 1 : 0
      end

      def usage_scan(git, sha)
        return nil unless config.usages?

        require_relative "../usages/scanner"
        DialectoRails::Usages::Scanner.new(git: git, sha: sha, config: config).call
      rescue LoadError
        usages_unavailable("the usage scan isn't available in this build")
      rescue Error
        raise
      rescue => e
        usages_unavailable("the usage scan failed (#{e.class}: #{e.message})")
      end

      def usages_unavailable(reason)
        raise ConfigError, "#{reason}; usages are required (--require-usages)." if @flags[:require_usages] || config.require_usages?

        @err.puts("Sending the catalogs without call sites: #{reason}. Renames stay unavailable until a scan carries them.")
        nil
      end

      def report(answer)
        outcome = answer["outcome"]
        write_outputs("scan-id" => answer["scan_id"], "outcome" => outcome)
        if outcome == "idempotent"
          @out.puts("Already scanned (scan #{answer["scan_id"]}); nothing changed.")
        else
          counts = answer["counts"] || {}
          @out.puts("Scan #{answer["scan_id"]} ingested: " \
                    "#{counts.map { |name, value| "#{value} #{name}" }.join(", ")}.")
        end
        Array(answer["skipped"]).each do |file|
          @out.puts("  skipped #{file["path"]}: #{file["message"] || file["reason"]}")
        end
      end

      ## doctor

      def doctor
        parse_flags
        git = Git.new(@root)
        checks = []
        checks << ["Ruby #{RUBY_VERSION}", RUBY_VERSION >= "3.2", "Dialecto's Rails SDK needs Ruby 3.2 or newer."]
        checks << ["git repository", git.repository?, "Run it inside the project's git checkout."]
        remote = git.repository? ? git.remote_url : nil
        checks << ["origin remote #{remote || "(none)"}", !remote.to_s.empty?, "Add an origin remote: `git remote add origin <url>`."]
        checks << ["catalog files at HEAD", catalogs_present?(git), "No file matches #{config.catalog_paths.join(", ")}: set DIALECTO_CATALOG_PATHS."]
        token = config.scan_token
        checks << ["scan token set", !token.nil?, "Set DIALECTO_SCAN_TOKEN (Settings → Scan token)."]
        checks << ["scan token shape", token.nil? || token.match?(TOKEN_SHAPE), "The token should look like dlk_ followed by 43 characters; copy it exactly as Dialecto showed it."]
        checks << ["project #{config.project || "(unset)"}", !!config.project&.match?(/\A\d+\z/), "Set DIALECTO_PROJECT to the project's number."]
        checks << ["url #{config.url}", config.url_problem.nil?, config.url_problem.to_s]
        checks << parsers_check
        checks << server_check(token) if token && config.project&.match?(/\A\d+\z/) && config.url_problem.nil?

        checks.each { |label, ok, fix| @out.puts("#{ok ? "ok  " : "FAIL"} #{label}#{ok ? "" : "\n     #{fix}"}") }
        worker_warning
        checks.all? { |_label, ok, _fix| ok } ? 0 : 2
      end

      # The in-context editor keeps its drafts and markers in memory, one copy per worker process.
      def worker_warning
        workers = @env["WEB_CONCURRENCY"].to_i
        return unless workers > 1

        @out.puts("warn WEB_CONCURRENCY=#{workers}\n     The in-context editor holds its state per process; with several workers a draft may " \
                  "vanish on the next request. Run the development server with one worker (the Rails default).")
      end

      def catalogs_present?(git)
        return false unless git.repository?

        catalogs = Catalogs.new(config.catalog_paths)
        git.entries(git.head_sha).any? { |entry| catalogs.match?(entry.path) }
      rescue Error
        false
      end

      def parsers_check
        require "prism"
        ["prism #{Prism::VERSION}", true, ""]
      rescue LoadError
        ["prism", false, "Install it: gem install prism."]
      end

      def server_check(_token)
        client = @client_factory.call(config)
        client.scan_config
        ["Dialecto accepts the token", true, ""]
      rescue RefusedError, RetryableError => e
        ["Dialecto accepts the token", false, e.message]
      end
    end
  end
end
