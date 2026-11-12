source "https://rubygems.org"

gemspec

# The in-context tests boot a real Rails app; CI sets RAILS_VERSION for each supported release.
group :test do
  # The usage scan reads HAML when the app's bundle has it; the tests and the rename check run with it.
  gem "haml"
  gem "minitest"
  gem "rack-test"
  gem "rails", ENV["RAILS_VERSION"] ? "~> #{ENV["RAILS_VERSION"]}.0" : ">= 7.1"
  gem "rake"
end
