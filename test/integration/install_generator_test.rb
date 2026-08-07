# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "../../lib/generators/solid_objects/install_generator"

class InstallGeneratorTest < ActiveSupport::TestCase
  test "generates an inert initializer with onboarding guidance" do
    Dir.mktmpdir do |directory|
      generator = SolidObjects::Generators::InstallGenerator.new
      generator.destination_root = directory

      capture_io { generator.copy_initializer }

      initializer = File.read(
        File.join(directory, "config/initializers/solid_objects.rb")
      )
      assert_includes initializer, "fresh installation is intentionally"
      assert_includes initializer, "authorization_context"
      assert_includes initializer, "docs/authorization.md"
      assert_includes initializer, "bin/rails solid_objects:doctor"
      assert_includes initializer, "instance_retention_by_actor_type"
      assert_includes initializer, "authorization_context[:source] == \"cli\""
      assert_includes initializer, "component_authorization_context"
      refute_includes initializer, "component_authorization_context = lambda"
      assert_equal 5, initializer.scan("= ->(**) { false }").length
    end
  end
end
