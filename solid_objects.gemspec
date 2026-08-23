# rbs_inline: enabled

require_relative "lib/solid_objects/version"

Gem::Specification.new do |spec|
  repository_url = "https://github.com/cardmagic/solid-objects-ruby"

  spec.name = "solid_objects"
  spec.version = SolidObjects::VERSION
  spec.authors = [ "Lucas Carlson" ]
  spec.summary = "Cloudflare Durable Objects, ported to Rails"
  spec.description = "The Cloudflare Durable Objects programming model for Rails: addressable objects with durable state, ordered mailboxes, fenced activation, per-object alarms, transactional effects, and reactive ERB. It runs on MySQL, PostgreSQL, and SQLite without requiring Redis."
  spec.homepage = "https://solidobjects.dev"
  spec.license = "MIT"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "bug_tracker_uri" => "#{repository_url}/issues",
    "changelog_uri" => "#{repository_url}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{repository_url}#readme",
    "homepage_uri" => spec.homepage,
    "rubygems_mfa_required" => "true",
    "source_code_uri" => repository_url
  }

  spec.required_ruby_version = ">= 3.3"

  spec.files = Dir[
    "{app,benchmark,config,db,docs,examples,exe,lib,sig,web}/**/*",
    "CHANGELOG.md",
    "README.md",
    "Rakefile",
    "MIT-LICENSE"
  ]
  spec.bindir = "exe"
  spec.executables = [ "solid_objects" ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "actioncable", ">= 7.1"
  spec.add_dependency "actionpack", ">= 7.1"
  spec.add_dependency "actionview", ">= 7.1"
  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  # The operator dashboard is a Rack application. Rack arrives with Action Pack
  # in every supported Rails version; the floor is stated because the dashboard
  # writes lowercase response headers, which Rack 3 requires.
  spec.add_dependency "rack", ">= 3.1"
  spec.add_dependency "railties", ">= 7.1"
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
  spec.add_development_dependency "trilogy", ">= 2.7"
end
