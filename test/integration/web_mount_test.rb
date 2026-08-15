# frozen_string_literal: true

require "test_helper"
require "open3"

# A Rack application behaves differently under a real Rails router than under a
# mock environment. The mount supplies SCRIPT_NAME, the Rails session
# middleware supplies the session CSRF protection needs, and a dashboard nested
# below the engine mount is only reachable because the engine cascades a path
# it does not serve. This runs the dashboard where it actually runs.
class WebMountTest < ActiveSupport::TestCase
  test "serves the dashboard from a real Rails mount" do
    assert_equal "403", results.fetch("denied"), "an unauthorized request must not reach a page"
    assert_equal "200", results.fetch("allowed")
    assert_equal "true", results.fetch("actor"), "the page must show data read through the mount"
    assert_equal "true", results.fetch("mounted_link"), "assets must be linked below the mount path"
    assert_equal "true", results.fetch("session"), "the Rails session must reach the dashboard"
  end

  test "rejects a forged token and applies a valid one through the Rails session" do
    assert_equal "403", results.fetch("forged")
    assert_equal "false", results.fetch("forged_paused"), "a forged token must not change the runtime"
    assert_equal "302", results.fetch("paused")
    assert_equal "/solid_objects/dashboard/instances/1", results.fetch("paused_location")
    assert_equal "true", results.fetch("paused_at")
  end

  private

  def results
    @results ||= begin
      output, error_output, status = Open3.capture3(
        Gem.ruby,
        File.expand_path("../dummy/web_mount_check.rb", __dir__)
      )
      assert status.success?, error_output
      output.split("\n").to_h { |line| line.split("=", 2) }
    end
  end
end
