require "json"
require "open3"

desc "Run the usage scan over the rails-src corpus (spec-0023 §9.3): rake corpus[DIR] (default ~/code/ddd/corpus/rails-src)"
task :corpus, [:dir] do |_task, args|
  root = File.expand_path(args[:dir] || "~/code/ddd/corpus/rails-src")
  abort "No corpus at #{root}: ONLY=rails-src bash ddd-plan/engineering/corpus/fetch.sh" unless File.directory?(root)

  rows = Dir.children(root).sort.filter_map do |name|
    app = File.join(root, name)
    next unless File.directory?(app)

    out, err, status = Open3.capture3("/usr/bin/time", "-l", RbConfig.ruby, "-Ilib", "tasks/corpus_app.rb", app)
    unless status.success?
      puts "#{name}: FAILED\n#{err.lines.first(8).join}"
      next
    end
    peak = err[/(\d+)\s+maximum resident set size/, 1].to_i / (1024.0 * 1024)
    JSON.parse(out).merge("peak_mb" => peak.round)
  end

  puts format("%-18s %5s %5s %5s %7s %7s %8s %7s %6s %7s %6s", "app", "rb", "erb", "haml", "records", "found", "dynamic", "literal", "unparse", "sec", "MB")
  rows.each do |row|
    puts format("%-18s %5d %5d %5d %7d %7d %8d %7d %6d %7.1f %6d", row["app"], row["files"]["rb"], row["files"]["erb"],
      row["files"]["haml"], row["records"], row["found"], row["dynamic"].values.sum, row["kinds"].fetch("literal", 0),
      row["unparseable"], row["seconds"], row["peak_mb"])
  end
  rows.each do |row|
    puts "\n#{row["app"]}: dynamic #{row["dynamic"]}; conventions #{row["conventions"]}; classes #{row["classes"]}; " \
         "unscanned other #{row["unscanned_other"]}; check #{row["check"]}"
    puts "  unparseable: #{row["unparseable_first"].map { |item| "#{item["file"]} (#{item["reason"][0, 90]})" }.join("; ")}" if row["unparseable"].positive?
    puts "  GATE FAIL (ruby accepts, Prism rejects): #{row["ruby_accepts_prism_rejects"].first(5)}" unless row["ruby_accepts_prism_rejects"].empty?
  end
end
