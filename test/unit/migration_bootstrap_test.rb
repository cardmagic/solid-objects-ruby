# frozen_string_literal: true

require "test_helper"

class MigrationBootstrapTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  test "no script names a migration class from a hand-copied list" do
    offenders = ruby_files.select do |file|
      body = File.read(file)
      migration_classes.any? { |name| body.include?(name) }
    end

    assert_empty offenders.map { |file| file.delete_prefix("#{ROOT}/") },
      "apply migrations through SolidObjects::SchemaBootstrap so the list cannot drift"
  end

  private

  def migration_classes
    Dir[File.join(ROOT, "db/migrate/*.rb")].map do |file|
      File.basename(file, ".rb").sub(/\A\d+_/, "").camelize
    end
  end

  def ruby_files
    Dir[File.join(ROOT, "{lib,test,examples,benchmark}/**/*.rb")] - [
      File.join(ROOT, "test/unit/migration_bootstrap_test.rb")
    ]
  end
end
