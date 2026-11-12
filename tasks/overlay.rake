require "fileutils"

# For maintainers of the gem: live mode serves a copy of Dialecto's built overlay from the site's own origin.
# Build it in the Dialecto repository first (`mix esbuild in_context`); a test there fails when this copy
# differs from a fresh build.
namespace :overlay do
  desc "Copies Dialecto's built overlay into lib/dialecto_rails/in_context/assets (FROM=path to override)"
  task :refresh do
    from = ENV.fetch("FROM", File.expand_path("../../priv/static/assets/in-context/overlay.js", __dir__))
    abort "No overlay at #{from}. Build it in the Dialecto repository: mix esbuild in_context" unless File.file?(from)

    to = File.expand_path("../lib/dialecto_rails/in_context/assets/overlay.js", __dir__)
    FileUtils.mkdir_p(File.dirname(to))
    FileUtils.cp(from, to)
    puts "Copied #{from} to #{to}"
  end
end
