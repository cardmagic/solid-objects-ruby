# frozen_string_literal: true

require "test_helper"
require "open3"

# Requiring the gem must not load ActiveRecord::Base. A host application and
# other gems register `ActiveSupport.on_load(:active_record)` hooks from a
# railtie initializer. A hook that is registered after the constant is already
# loaded runs at once, before the `config/initializers` files that supply its
# configuration, so the timing of the load decides whether that configuration
# arrives at all.
class ActiveRecordLoadTimingTest < ActiveSupport::TestCase
  test "requiring the gem leaves the active record load hooks deferred" do
    assert_equal "deferred", probe_result,
      "the gem loads ActiveRecord::Base at require time, so host application hooks run too early"
  end

  # The reported breakage: an application that assigns its encryption keys in
  # `config/initializers` lost them, because the railtie hook that reads them
  # had already run.
  test "an application initializer configures Active Record encryption" do
    output, error_output, status = Open3.capture3(
      Gem.ruby,
      File.expand_path("../dummy/encryption_configuration_check.rb", __dir__)
    )

    assert status.success?, error_output
    assert_equal "solid-objects-dummy-primary-key", output.strip
  end

  private

  # Computed in a fresh process, because this process loaded Active Record long
  # before the question was asked.
  def probe_result
    output, error_output, status = Open3.capture3(
      { "BUNDLE_GEMFILE" => gem_root("Gemfile") },
      Gem.ruby,
      "-e",
      probe,
      chdir: gem_root(".")
    )
    assert status.success?, error_output
    output.strip
  end

  def probe
    <<~RUBY
      require "rails"
      require "active_record/railtie"
      require "solid_objects"

      fired = false
      ActiveSupport.on_load(:active_record) { fired = true }
      puts(fired ? "immediate" : "deferred")
    RUBY
  end

  def gem_root(path)
    File.expand_path("../../#{path}", __dir__)
  end
end
