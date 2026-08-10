# frozen_string_literal: true

require "test_helper"
require "open3"
require "solid_objects/cli"
require "sqlite3"
require "tmpdir"

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

  # Deny-by-default means an unconfigured host hits this on its first CLI
  # command, so it is the most likely thing a new adopter ever sees.
  test "a denied command reports the policy rather than a backtrace" do
    Dir.mktmpdir("solid-objects-cli") do |directory|
      dummy_root = File.expand_path("../dummy", __dir__)
      _output, error_output, status = Open3.capture3(
        {
          "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
          "RAILS_ENV" => "test",
          "SOLID_OBJECTS_DUMMY_DATABASE" => File.join(directory, "dummy.sqlite3")
        },
        "bundle", "exec", "solid_objects", "status",
        chdir: dummy_root
      )

      refute status.success?, "a denied command must exit non-zero"
      assert_match(/authorize_administration/, error_output,
        "the message should name the setting that grants access")
      refute_match(/lib\/solid_objects\/cli\.rb:\d+/, error_output,
        "a policy decision is not a crash and should not print a backtrace")
    end
  end

  test "start loads and processes application actors when eager loading is disabled" do
    Dir.mktmpdir("solid-objects-cli") do |directory|
      database = File.join(directory, "dummy.sqlite3")
      completed = File.join(directory, "completed")
      environment = {
        "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
        "RAILS_ENV" => "test",
        "SOLID_OBJECTS_CLI_WORKER_PROBE" => completed,
        "SOLID_OBJECTS_DUMMY_DATABASE" => database
      }
      dummy_root = File.expand_path("../dummy", __dir__)
      prepare = File.join(dummy_root, "prepare_cli_worker.rb")
      _output, prepare_error, prepare_status = Open3.capture3(
        environment,
        Gem.ruby,
        prepare,
        chdir: dummy_root
      )
      assert prepare_status.success?, prepare_error

      _input, output, error_output, wait_thread = Open3.popen3(
        environment,
        "bundle",
        "exec",
        "solid_objects",
        "start",
        "--workers",
        "1",
        "--effect-workers",
        "0",
        "--broadcast-workers",
        "0",
        "--reminder-schedulers",
        "0",
        chdir: dummy_root
      )
      status = Timeout.timeout(10) { wait_thread.value }

      assert status.success?, [ output.read, error_output.read ].join("\n")
      assert File.exist?(completed)

      connection = SQLite3::Database.new(database)
      state, completed_at = connection.get_first_row(
        "SELECT state, completed_at FROM solid_objects_messages INNER JOIN " \
          "solid_objects_instances ON solid_objects_instances.id = solid_objects_messages.instance_id"
      )
      assert_equal({ "completed" => true }, JSON.parse(state))
      assert completed_at
    ensure
      connection&.close
      Process.kill("TERM", wait_thread.pid) if wait_thread&.alive?
      wait_thread&.join
    end
  end
end
