# frozen_string_literal: true

require "test_helper"
require "open3"
require "solid_objects/cli"

class CLITest < ActiveSupport::TestCase
  test "documents the operational commands" do
    executable = File.expand_path("../../exe/solid_objects", __dir__)

    output, error_output, status = Open3.capture3(Gem.ruby, executable, "help")

    assert status.success?, error_output
    assert_includes output, "solid_objects start"
    assert_includes output, "solid_objects status"
    assert_includes output, "solid_objects cleanup"
    assert_includes output, "solid_objects prune_messages"
    assert_includes output, "solid_objects prune_instances"
    assert_includes output, "solid_objects prune_processes"
    assert_includes output, "solid_objects dead_letters"
    assert_includes output, "solid_objects retry_dead_letter"
  end

  test "requires administration authorization before process inspection" do
    command = SolidObjects::CLI.new
    command.define_singleton_method(:boot_application) { nil }

    assert_raises(SolidObjects::Unauthorized) { command.status }
  end

  test "requires administration authorization before process cleanup" do
    command = SolidObjects::CLI.new
    command.define_singleton_method(:boot_application) { nil }

    assert_raises(SolidObjects::Unauthorized) { command.cleanup }
  end

  test "requires administration authorization before message pruning" do
    command = SolidObjects::CLI.new
    command.define_singleton_method(:boot_application) { nil }

    assert_raises(SolidObjects::Unauthorized) { command.prune_messages }
  end
end
