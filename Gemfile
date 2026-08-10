source "https://rubygems.org"

gemspec

# Compatibility runs pin the Rails line so CI can verify the span the gemspec
# advertises rather than only the newest release that resolves.
rails_version = ENV["RAILS_VERSION"]
if rails_version
  constraint = "~> #{rails_version}.0"
  %w[actioncable actionpack actionview activerecord activesupport railties].each do |library|
    gem library, constraint
  end
end

group :development, :test do
  gem "mysql2", ">= 0.5", require: false
  gem "pg", ">= 1.5", require: false
  gem "sqlite3", ">= 2.1", require: false
end

group :development do
  gem "brakeman", require: false
  gem "rbs-inline", require: false
  gem "standard", require: false
  gem "steep", require: false
end
