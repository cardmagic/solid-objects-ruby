# frozen_string_literal: true

require "test_helper"
require "solid_objects/web"

class WebHelpersTest < ActiveSupport::TestCase
  # The Ruby side of the table in test/javascript/dashboard.test.mjs. The
  # summary bar renders these on the server and the poller rewrites the same
  # cells in the browser, so a value that formats differently in one place
  # reads as a different measurement.
  DURATIONS = {
    0.0 => "0.000 s",
    4.25 => "4.250 s",
    59.999 => "59.999 s",
    60.0 => "1 min 0 s",
    511.892 => "8 min 32 s"
  }.freeze

  COUNTS = {
    0 => "0",
    12 => "12",
    1_234_567 => "1,234,567"
  }.freeze

  class Subject
    include SolidObjects::Web::Helpers
  end

  setup do
    @helpers = Subject.new
  end

  test "formats a duration the way the browser poller formats it" do
    DURATIONS.each do |seconds, rendered|
      assert_equal rendered, @helpers.duration(seconds), "#{seconds} must render as #{rendered}"
    end
  end

  test "formats a count with thousands separators" do
    COUNTS.each do |value, rendered|
      assert_equal rendered, @helpers.number(value), "#{value} must render as #{rendered}"
    end
  end

  test "renders a missing duration as a dash rather than zero" do
    assert_equal "&mdash;", @helpers.duration(nil)
  end

  test "escapes text that came from an application" do
    assert_equal "&lt;script&gt;", @helpers.h("<script>")
    assert_equal "&amp;", @helpers.h("&")
  end

  test "truncates a payload rather than rendering an unbounded one" do
    truncated = @helpers.truncate("a" * 3_000, 100)

    assert_equal 101, truncated.length
    assert truncated.end_with?("…")
  end

  test "renders a JSON payload as escaped text" do
    rendered = @helpers.json_block({ "name" => "<script>" })

    assert_includes rendered, "&lt;script&gt;"
    refute_includes rendered, "<script>"
  end

  test "renders a payload JSON cannot generate rather than raising" do
    rendered = @helpers.json_block(Object.new)

    assert_includes rendered, "Object"
  end
end
