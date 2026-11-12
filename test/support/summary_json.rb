# Prints the classification of every catalog key as JSON: the gem's side of the parity test that holds
# `usages --summary` to the server's classification (dlocal test/dlocal/localize/rails_summary_parity_test.exs).
#
#   ruby -I lib test/support/summary_json.rb ENVELOPE.json KEYS.json
require "json"
require_relative "../../lib/dialecto_rails/usages/summary"

envelope = JSON.parse(File.read(ARGV.fetch(0)))
keys = JSON.parse(File.read(ARGV.fetch(1)))
rows = DialectoRails::Usages::Summary.new(envelope, keys).rows

puts JSON.generate(rows.to_h { |row| [row.key, { "class" => row.klass.to_s, "prefix" => row.prefix }.compact] })
