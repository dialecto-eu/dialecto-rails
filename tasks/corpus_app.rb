# One corpus app, scanned and summarised as JSON on stdout. Run by `rake corpus` under `/usr/bin/time -l`, so
# peak memory is measured per app. Usage: ruby -Ilib tasks/corpus_app.rb APP_DIR
require "json"
require "open3"
require "dialecto_rails"
require "dialecto_rails/scan/git"
require "dialecto_rails/scan/worktree"
require "dialecto_rails/usages/scanner"
require "dialecto_rails/usages/summary"
require "dialecto_rails/usages/check"

dir = File.expand_path(ARGV.fetch(0))
# Monorepos keep catalogs in every engine's config/locales (the corpus table's `**/config/locales/`).
require_relative "corpus_config"
config = corpus_config(dir)
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
scanner = DialectoRails::Usages::Scanner.new(git: DialectoRails::Scan::Worktree.new(dir), sha: nil, config: config)
envelope = scanner.call
seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

usages = envelope["usages"]
dynamic = usages.select { |usage| usage["kind"] == "pattern" }.group_by { |usage| usage["reason"] }
  .transform_values(&:length).sort_by { |_, count| -count }.to_h
unscanned = envelope["unscanned"]
parse_errors = unscanned.select { |item| item["reason"].start_with?("could not be parsed") }

# Gate: a file Prism rejects must be one Ruby rejects too.
ruby_accepts = parse_errors.select { |item| item["file"].end_with?(".rb") }.select do |item|
  _out, _err, status = Open3.capture3("ruby", "-c", File.join(dir, item["file"]))
  status.success?
end

entries = DialectoRails::Scan::Worktree.new(dir).entries
summary = DialectoRails::Usages::Summary.new(envelope, scanner.catalog.keys.to_a)
kinds = usages.group_by { |usage| usage["kind"] }.transform_values(&:length)
findings = DialectoRails::Usages::Check.new(envelope, scanner.catalog).findings

puts JSON.generate(
  "app" => File.basename(dir), "seconds" => seconds.round(1),
  "files" => {"rb" => entries.count { |e| e.path.end_with?(".rb") }, "erb" => entries.count { |e| e.path.end_with?(".erb") },
              "haml" => entries.count { |e| e.path.end_with?(".haml") }},
  "records" => usages.length, "kinds" => kinds,
  "found" => kinds.fetch("static", 0) + kinds.fetch("set", 0), "dynamic" => dynamic, "conventions" => envelope["conventions"].length,
  "unparseable" => parse_errors.length, "unparseable_first" => parse_errors.first(3),
  "ruby_accepts_prism_rejects" => ruby_accepts.map { |item| item["file"] },
  "unscanned_other" => (unscanned - parse_errors).group_by { |item| item["reason"] }.transform_values(&:length),
  "classes" => summary.counts.transform_keys(&:to_s), "catalog_keys" => scanner.catalog.keys.length,
  "check" => findings.group_by(&:code).transform_values(&:length),
  "gems" => envelope["gems"].length
)
