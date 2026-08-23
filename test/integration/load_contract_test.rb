# frozen_string_literal: true

require "test_helper"
require "open3"

# Runtime roles run in `solid_objects start`, a process that requires the gem
# and nothing else. A constant reached only through the caller path resolves
# fine in this test process, where everything is already loaded, and raises
# NameError in that worker. Asking a fresh process what `require
# "solid_objects"` actually defines is the only way to see the difference.
class LoadContractTest < ActiveSupport::TestCase
  # Each of these is deliberately not loaded by requiring the gem. Anything
  # else that stops being loaded is a role waiting to fail in production, so
  # this list is the place to argue that a role never reaches it.
  DEFERRED = {
    "caller_process" => "the caller path, required by SolidObjects.caller_process",
    "cli" => "loaded by exe/solid_objects, and pulls in thor",
    "client" => "the caller path, required by SolidObjects.client",
    "doctor" => "an operator tool, loaded by the doctor command",
    "errors" => "defines error classes individually, so no SolidObjects::Errors exists",
    "sync_diagnostics" => "the caller path, required with the client",
    "synchronous_invocation" => "the caller path, required with the client",
    "test_helper" => "opt-in, required by host application tests",
    "web" => "the operator dashboard, required by an application that mounts it",
    "web/action" => "loaded with the dashboard",
    "web/application" => "loaded with the dashboard",
    "web/csrf_protection" => "loaded with the dashboard",
    "web/helpers" => "loaded with the dashboard",
    "web/paginator" => "loaded with the dashboard",
    "web/route" => "loaded with the dashboard",
    "web/router" => "loaded with the dashboard",
    "web/statistics" => "loaded with the dashboard"
  }.freeze

  test "requiring the gem defines everything a runtime role reaches for" do
    assert_equal DEFERRED.keys.sort, undefined_after_require,
      "a file that stopped being loaded is only safe if no runtime role reaches it"
  end

  # The reported failure: two roles enqueue through the mailbox, and requiring
  # the gem did not define it.
  test "the mailbox is defined by requiring the gem" do
    refute_includes undefined_after_require, "mailbox",
      "the reminder scheduler and effect executor enqueue through it"
  end

  private

  # Computed inside the fresh process, where both the file list and what the
  # require actually defined are available.
  def undefined_after_require
    @undefined_after_require ||= begin
      output, error_output, status = Open3.capture3(
        { "BUNDLE_GEMFILE" => gem_root("Gemfile") },
        Gem.ruby,
        "-e",
        probe,
        chdir: gem_root(".")
      )
      assert status.success?, error_output
      output.split("\n").sort
    end
  end

  def probe
    <<~RUBY
      require "solid_objects"

      def classify(path)
        path.split("/").map { |part| part.split("_").map(&:capitalize).join }.join("::")
      end

      undefined = Dir.glob("**/*.rb", base: "lib/solid_objects").filter_map do |path|
        file = path.delete_suffix(".rb")
        next if file == "version"

        begin
          Object.const_get("SolidObjects::" + classify(file))
          nil
        rescue NameError
          file
        end
      end
      puts undefined
    RUBY
  end

  def gem_root(path)
    File.expand_path("../../#{path}", __dir__)
  end
end
