# frozen_string_literal: true

require "test_helper"

class GemSpecificationTest < ActiveSupport::TestCase
  setup do
    @specification = Gem::Specification.load(
      File.expand_path("../../solid_objects.gemspec", __dir__)
    )
  end

  test "links the homepage to the Rails page" do
    assert_equal "https://solidobjects.dev/ruby", @specification.homepage
    assert_equal @specification.homepage, @specification.metadata.fetch("homepage_uri")
  end

  test "names the virtual actor category for Rails" do
    assert_match(/virtual actors?/i, @specification.summary)
    assert_match(/Rails/, @specification.summary)
    assert_match(/SQL-backed virtual actor library for Ruby on Rails/, @specification.description)
  end

  test "packages the agent and category guides" do
    assert_includes @specification.files, "docs/agents.md"
    assert_includes @specification.files, "docs/virtual-actors.md"
  end
end
