# frozen_string_literal: true

require "test_helper"
require "open3"

class EngineTest < ActiveSupport::TestCase
  test "boots when Action View loads before the engine initializer" do
    command = [
      Gem.ruby,
      File.expand_path("../dummy/boot_check.rb", __dir__)
    ]

    output, error_output, status = Open3.capture3(*command)

    assert status.success?, error_output
    assert_equal "solid_objects_dummy_booted", output.strip
  end

  # An actor registers itself as a side effect of its class loading. A web
  # process resolves actors by name for Cable subscriptions and component
  # renders, so a lazily loading process that boots with an empty registry
  # rejects a live subscription for an actor it is able to serve.
  test "registers application actors in a process that does not eager load" do
    command = [
      Gem.ruby,
      File.expand_path("../dummy/actor_registry_check.rb", __dir__)
    ]

    output, error_output, status = Open3.capture3(*command)

    assert status.success?, error_output
    assert_equal "registered", output.strip
  end

  test "resolves the component endpoint from the engine mount" do
    command = [
      Gem.ruby,
      File.expand_path("../dummy/component_path_check.rb", __dir__)
    ]

    output, error_output, status = Open3.capture3(*command)

    assert status.success?, error_output
    assert_equal "/solid_objects/components", output.strip
  end

  # The configuration arrives in `config/initializers`, and the record class
  # reads it when it loads, which is after those files run.
  test "connects the record class to the configured database" do
    command = [
      Gem.ruby,
      File.expand_path("../dummy/connects_to_check.rb", __dir__)
    ]

    output, error_output, status = Open3.capture3(*command)

    assert status.success?, error_output
    assert_equal "ActiveRecord::Base SolidObjects::Record", output.strip
  end

  test "packages the morph refresh browser module" do
    specification = Gem::Specification.load(
      File.expand_path("../../solid_objects.gemspec", __dir__)
    )

    assert_includes specification.files,
      "app/assets/javascripts/solid_objects/component_refresh.js"
  end
end
