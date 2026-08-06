# rbs_inline: enabled

require_relative "lib/solid_objects/version"

Gem::Specification.new do |spec|
  spec.name = "solid_objects"
  spec.version = SolidObjects::VERSION
  spec.authors = [ "Lucas Carlson" ]
  spec.summary = "Database-backed virtual actors for Rails"
  spec.description = "A Rails-native virtual actor runtime with durable state, ordered mailboxes, fenced activation leases, reminders, transactional effects, and reactive views. It runs on MySQL, PostgreSQL, and SQLite without requiring Redis."
  spec.homepage = "https://github.com/cardmagic/solid_objects"
  spec.license = "MIT"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "homepage_uri" => spec.homepage,
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage
  }

  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir[
    "{app,benchmark,config,db,docs,examples,exe,lib,sig}/**/*",
    "CHANGELOG.md",
    "README.md",
    "Rakefile",
    "MIT-LICENSE"
  ]
  spec.bindir = "exe"
  spec.executables = [ "solid_objects" ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "actioncable", ">= 8.0"
  spec.add_dependency "actionpack", ">= 8.0"
  spec.add_dependency "actionview", ">= 8.0"
  spec.add_dependency "activerecord", ">= 8.0"
  spec.add_dependency "activesupport", ">= 8.0"
  spec.add_dependency "railties", ">= 8.0"
  spec.add_dependency "thor", ">= 1.3"

  spec.add_development_dependency "benchmark"
  spec.add_development_dependency "brakeman"
  spec.add_development_dependency "minitest"
  spec.add_development_dependency "mysql2", ">= 0.5"
  spec.add_development_dependency "pg", ">= 1.5"
  spec.add_development_dependency "rbs-inline"
  spec.add_development_dependency "rubocop-rails-omakase"
  spec.add_development_dependency "sqlite3", ">= 2.1"
  spec.add_development_dependency "standard"
  spec.add_development_dependency "steep"
end
