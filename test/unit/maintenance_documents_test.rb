# frozen_string_literal: true

require "test_helper"

class MaintenanceDocumentsTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  MAINTAINER_COUNT = /\b(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|only|sole|single)\s+maintainers?\b/i

  def guide(path)
    File.read(File.join(ROOT, path))
  end

  test "the README links to the maintenance page" do
    assert_includes guide("README.md"), "(docs/maintenance.md)"
  end

  test "the maintenance page names the lead maintainer" do
    assert_match(
      %r{Lucas Carlson \(\[@cardmagic\]\(https://github\.com/cardmagic\)\) is the lead\s+maintainer},
      guide("docs/maintenance.md")
    )
  end

  test "the count pattern finds a count of maintainers in each form" do
    [ "One maintainer.", "1 maintainer", "two maintainers", "the only\nmaintainer" ].each do |text|
      assert_match MAINTAINER_COUNT, text
    end
    [ "the lead maintainer", "wants more maintainers", "become a maintainer" ].each do |text|
      refute_match MAINTAINER_COUNT, text
    end
  end

  test "no page states a count of maintainers" do
    paths = [ "README.md", "CONTRIBUTING.md", *Dir.glob("docs/**/*.md", base: ROOT).sort ]
    pages = paths.select { |path| guide(path).match?(MAINTAINER_COUNT) }

    assert_empty pages
  end

  test "the maintenance page tells a contributor how to start" do
    assert_includes guide("docs/maintenance.md"), "(../CONTRIBUTING.md)"
  end
end
