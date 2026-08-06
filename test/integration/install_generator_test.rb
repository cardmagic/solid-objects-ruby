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
      assert_equal 5, initializer.scan("= ->(**) { false }").length
    end
  end
end
