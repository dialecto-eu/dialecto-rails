require "test_helper"
require "json"
require "find"
require "dialecto_rails/usages/scanner"

# Every case of the frozen `railsUsages` contract (test/contract/*): scan its tree, compare with expected.json.
class UsagesContractTest < Minitest::Test
  CONTRACT = File.expand_path("../contract", __dir__)

  def self.scan(dir)
    files = {}
    tree = File.join(dir, "tree")
    Find.find(tree) do |path|
      next unless File.file?(path)

      files[path.delete_prefix("#{tree}/")] = File.binread(path)
    end
    repo = GitFixture.new(files)
    git = DialectoRails::Scan::Git.new(repo.root)
    DialectoRails::Usages::Scanner.new(git: git, sha: git.head_sha, config: DialectoRails::Config.new({}, {})).call
  ensure
    repo&.cleanup
  end

  Dir.children(CONTRACT).sort.each do |name|
    dir = File.join(CONTRACT, name)
    next unless File.directory?(dir)

    define_method("test_case_#{name.tr("-", "_")}") do
      expected = JSON.parse(File.read(File.join(dir, "expected.json")))
      actual = JSON.parse(JSON.generate(self.class.scan(dir)))
      actual.delete("parsers")
      expected.delete("parsers")
      %w[version gems unscanned conventions].each { |key| assert_equal expected[key], actual[key], "#{name}: #{key}" }
      assert_equal expected["usages"].length, actual["usages"].length, "#{name}: usage count\n#{JSON.pretty_generate(actual["usages"])}"
      expected["usages"].zip(actual["usages"]).each_with_index do |(want, got), index|
        assert_equal want, got, "#{name}: usage #{index}"
      end
    end
  end
end
