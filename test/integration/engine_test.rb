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
end
