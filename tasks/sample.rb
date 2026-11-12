# The hand-sampled precision check (spec-0023 §9.3): 200 records per app, drawn with a fixed seed, each judged
# against the source it came from. The judge below reads the anchor with plain regular expressions, independent
# of the scanner's Prism code; whatever it can't confirm is marked "check" and read by eye.
# Usage: ruby -Ilib tasks/sample.rb APP_DIR OUT.json
require "json"
require "dialecto_rails"
require "dialecto_rails/scan/git"
require "dialecto_rails/scan/worktree"
require "dialecto_rails/usages/scanner"

SEED = 20_261_007
SAMPLE = 200

# The first quoted string or symbol in an anchor: what a reader sees as "the key".
def literal_in(content)
  content.match(/(?:["']([^"'\\]*)["']|:"([^"]+)"|:'([^']+)'|:([A-Za-z_]\w*))/)&.captures&.compact&.first
end

def view_base(file)
  rel = file[%r{app/views/(.+)\z}, 1] or return nil
  *dirs, name = rel.split("/")
  (dirs + [name.split(".").first.delete_prefix("_")]).join(".")
end

# "ok", or the reason the judge can't confirm the record.
def judge(rec)
  content = rec["content"]
  case rec["kind"]
  when "static"
    lit = literal_in(content[/\A[^,]*/])
    return "check: no literal found in the anchor" unless lit

    if rec["lazy"]
      return "check: lazy key doesn't end with the literal" unless lit.start_with?(".") && rec["key"].end_with?(lit.delete_prefix("."))

      base = view_base(rec["file"])
      return "ok" if base && rec["key"] == "#{base}#{lit}"
      return "ok" unless %w[view partial].include?(rec["lazy"]["from"])

      return "check: lazy base #{rec["key"]} for #{rec["file"]}"
    end
    return "ok" if rec["key"] == lit
    return "ok" if rec["scope"] && rec["key"].end_with?(".#{lit}") && content.include?("scope")

    "check: key #{rec["key"]} vs literal #{lit}"
  when "literal"
    lit = content.sub(/\A:/, "").gsub(/\A["']|["']\z/, "")
    lit == rec["key"] ? "ok" : "check: literal #{rec["key"]} vs #{content}"
  when "set"
    rec["keys"].all? { |key| rec["via"] || rec["origin"] == "wrapper" || content.include?(key.split(".").first.to_s) } ? "ok" : "check: set keys"
  when "pattern"
    literals = rec["parts"].filter_map { |part| part["lit"] }
    literals.all? { |part| content.include?(part) || rec["lazy"] || rec["reason"].to_s.match?(/scope|lazy|splat|argument/) } ? "ok" : "check: pattern parts #{literals}"
  when "template"
    content.start_with?('"', "'") ? "ok" : "check: template anchor"
  else "check: kind"
  end
end

app = File.expand_path(ARGV.fetch(0))
require_relative "corpus_config"
config = corpus_config(app)
envelope = DialectoRails::Usages::Scanner.new(git: DialectoRails::Scan::Worktree.new(app), sha: nil, config: config).call
usages = envelope["usages"]
rng = Random.new(SEED + File.basename(app).sum)
drawn = usages.length <= SAMPLE ? usages.each_index.to_a : usages.each_index.to_a.sample(SAMPLE, random: rng)
# A call on a constant (`Spree.t`) is a newer form: every one of them is read, not only the drawn ones.
receivers = usages.each_index.select { |i| usages[i]["form"].match?(/\A(?!I18n\.)[A-Z]/) }
picked = (drawn | receivers).sort.map { |i| usages[i] }

rows = picked.map do |rec|
  file = File.binread(File.join(app, rec["file"])).force_encoding(Encoding::UTF_8)
  line = file.lines[rec["start_line"] - 1].to_s.strip[0, 200]
  # The anchor must be the file's bytes at the offset (a precondition of every record).
  anchored = file.b.byteslice(rec["offset"], rec["content"].bytesize) == rec["content"].b
  verdict = anchored ? judge(rec) : "WRONG: anchor is not the file's bytes"
  rec.slice("kind", "file", "start_line", "form", "key", "keys", "pattern", "reason", "origin", "lazy", "scope", "defaults")
    .merge("app" => File.basename(app), "content" => rec["content"][0, 160], "source_line" => line, "verdict" => verdict)
end

File.write(ARGV.fetch(1), JSON.pretty_generate(rows))
counts = rows.group_by { |row| row["verdict"][/\A\w+/] }.transform_values(&:length)
puts "#{File.basename(app)}: #{rows.length} sampled of #{usages.length}; #{counts}"
