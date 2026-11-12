# Herb's ERB segments against the stdlib ERB tokenizer's (spec-0023 §9.3), over every .erb file under a folder.
# For each file the stdlib scanner says which byte ranges are Ruby (`<% %>`, `<%= %>`; `<%# %>` comments and
# `<%%` escapes are not). Herb's extraction must hold the source's bytes in those ranges and nothing but
# blanks and `;` outside them. Usage: ruby -Ilib tasks/erb_check.rb DIR
require "erb"
require "herb"
require "json"
require "find"

Segment = Struct.new(:from, :to)

def stdlib_segments(source)
  scanner = ERB::Compiler::TrimScanner.new(source, nil, false)
  offset = 0
  stag = nil
  start = 0
  segments = []
  comments = []
  scanner.scan do |token|
    before = offset
    offset += token.bytesize
    if stag.nil?
      if ["<%", "<%=", "<%#"].include?(token)
        stag = token
        start = offset
      end
    elsif token == "%>"
      (stag == "<%#" ? comments : segments) << Segment.new(start, before)
      stag = nil
    end
  end
  return nil unless offset == source.bytesize

  [segments, comments]
end

def difference(source, extracted, segments, comments)
  problems = []
  inside = Array.new(source.bytesize, false)
  segments.each { |seg| (seg.from...seg.to).each { |i| inside[i] = true } }
  segments.each do |seg|
    want = source.byteslice(seg.from, seg.to - seg.from)
    got = extracted.byteslice(seg.from, seg.to - seg.from)
    # Herb may blank a Ruby run it can't use (a bare `%>` in a string); a difference is whatever isn't the source or blank.
    # `<%-` and `-%>` are trim markers (Rails' Erubi reads them so); Herb blanks them, the bare stdlib scan doesn't.
    # `<%==` is Erubi's raw output, so its second `=` is a marker too.
    trimmed = want.sub(/-\z/, " ").sub(/\A[-=]/, " ")
    problems << "code at #{seg.from} differs" unless [want, trimmed].include?(got) || got.to_s.strip.empty?
  end
  extracted.each_byte.with_index do |byte, index|
    next if inside[index] || [32, 10, 59, 13, 9].include?(byte)

    problems << "stray byte #{byte.chr.inspect} at #{index}"
    break
  end
  problems << "length differs" unless extracted.bytesize == source.bytesize
  problems
end

root = File.expand_path(ARGV.fetch(0))
files = 0
bad = []
skipped = []
Find.find(root) do |path|
  Find.prune if File.basename(path) == ".git"
  next unless File.file?(path) && path.end_with?(".erb")

  source = File.binread(path).force_encoding(Encoding::UTF_8)
  next unless source.valid_encoding?

  files += 1
  scanned = stdlib_segments(source)
  (skipped << path.delete_prefix("#{root}/") and next) unless scanned
  segments, comments = scanned
  problems = difference(source, Herb.extract_ruby(source), segments, comments)
  bad << {"file" => path.delete_prefix("#{root}/"), "problems" => problems.first(3)} unless problems.empty?
end
puts JSON.pretty_generate("files" => files, "differing" => bad.length, "stdlib_offsets_unusable" => skipped.length,
  "examples" => bad.first(12), "skipped_examples" => skipped.first(3))
