require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/{unit,integration}/**/*_test.rb"
  t.warning = false
end

load File.expand_path("tasks/corpus.rake", __dir__)
load File.expand_path("tasks/overlay.rake", __dir__)

task default: :test
