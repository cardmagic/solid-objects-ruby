# frozen_string_literal: true

require "test_helper"

class MaintenanceDocumentsTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)
  MAINTAINER_COUNT = /\b(?:one|only|sole|single)\s+maintainer\b/i

  def guide(path)
    File.read(File.join(ROOT, path))
  end

  def documentation_paths
    [ "README.md", "CONTRIBUTING.md", *Dir.glob("docs/**/*.md", base: ROOT).sort ]
  end

  test "the README links to the maintenance page" do
    assert_includes guide("README.md"), "(docs/maintenance.md)"
  end

  test "the maintenance page names the lead maintainer" do
    assert_match(/is the lead\s+maintainer/, guide("docs/maintenance.md"))
  end

  test "no page states a count of maintainers" do
    pages = documentation_paths.select { |path| guide(path).match?(MAINTAINER_COUNT) }

    assert_empty pages
  end

  test "the maintenance page tells a contributor how to start" do
    assert_includes guide("docs/maintenance.md"), "(../CONTRIBUTING.md)"
  end
end
