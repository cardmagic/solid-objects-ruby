# frozen_string_literal: true

require "test_helper"

class JsonCompatibilityTest < ActiveSupport::TestCase
  REFUSED_KEYWORD = ->(_text) { raise ArgumentError, "unknown keyword: :quirks_mode" }

  test "reports no problem when Active Support decodes JSON" do
    assert_nil SolidObjects::JsonCompatibility.new.problem
  end

  test "names the versions and the correction when Active Support cannot decode JSON" do
    problem = SolidObjects::JsonCompatibility.new(decode: REFUSED_KEYWORD).problem

    assert_includes problem, "unknown keyword: :quirks_mode"
    assert_includes problem, "json gem #{JSON::VERSION}"
    assert_includes problem, "Active Support #{ActiveSupport.version}"
    assert_includes problem, 'gem "json", "~> 2"'
  end

  test "does not hide a different decode failure" do
    broken = ->(_text) { raise NoMethodError, "decode is gone" }

    assert_raises(NoMethodError) { SolidObjects::JsonCompatibility.new(decode: broken).problem }
  end

  test "warns on the error stream when there is a problem" do
    _output, errors = capture_io { SolidObjects::JsonCompatibility.new(decode: REFUSED_KEYWORD).warn_about_problem }

    assert_includes errors, "[solid_objects]"
    assert_includes errors, 'gem "json", "~> 2"'
  end

  test "writes nothing when there is no problem" do
    output, errors = capture_io { SolidObjects::JsonCompatibility.new.warn_about_problem }

    assert_empty output
    assert_empty errors
  end

  test "the engine checks JSON compatibility during the boot" do
    names = SolidObjects::Engine.instance.initializers.map(&:name)

    assert_includes names, "solid_objects.json_compatibility"
  end
end
