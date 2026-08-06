# rbs_inline: enabled

require "bundler/gem_tasks"
require "fileutils"
require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

desc "Generate RBS signatures from inline annotations"
task :rbs do
  FileUtils.rm_rf(File.expand_path("sig/generated", __dir__))
  sh "bundle exec rbs-inline --base lib --base app --output sig/generated lib app"
  FileUtils.rm_f(File.expand_path("sig/generated/lib/generators/solid_objects/templates/solid_objects.rbs", __dir__))
  sh "bundle exec rbs -I sig/generated -I sig/support validate"
end

desc "Run Standard Ruby"
task :standard do
  sh "bundle exec standardrb"
end

desc "Run Solid Queue's RuboCop policy"
task :rubocop do
  sh "bundle exec rubocop"
end

desc "Type-check generated inline RBS signatures"
task :steep do
  sh "bundle exec steep check"
end

desc "Scan the Rails engine for security warnings"
task :security do
  sh "bundle exec brakeman --force --no-pager -q ."
end

task default: %i[test standard rubocop rbs steep security]
