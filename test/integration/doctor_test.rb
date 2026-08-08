# frozen_string_literal: true

require "database_test_helper"
require "rake"
require "solid_objects/doctor"

class DoctorTest < ActiveSupport::TestCase
  test "verifies a workerless synchronous installation" do
    SolidObjects.configuration.authorize_destroy = ->(**) { false }

    report = SolidObjects::Doctor.new.call

    assert report.healthy?
    assert_equal :pass, report.check(:configuration).status
    assert_equal :pass, report.check(:schema).status
    assert_equal :pass, report.check(:authorization).status
    assert_equal :pass, report.check(:sync_round_trip).status
    assert_equal :info, report.check(:runtime).status
    assert_match(/workerless synchronous calls are available/, report.check(:runtime).message)
    assert_empty SolidObjects::Instance.where(actor_type: "solid_objects_doctor")
    assert_empty SolidObjects::Process.where(kind: "caller")
  end

  test "runs its probe on a caller process the application cannot adopt" do
    SolidObjects.caller_process.define_singleton_method(:process_registry) do
      raise "the doctor probe must not share the application caller process"
    end

    report = SolidObjects::Doctor.new.call

    assert_equal :pass, report.check(:sync_round_trip).status
    assert_empty SolidObjects::Process.where(kind: "caller")
  ensure
    SolidObjects.reset_caller_process!
  end

  test "preserves a caller process the application registered before the probe" do
    existing_record = SolidObjects.caller_process.process_registry.process_record

    report = SolidObjects::Doctor.new.call

    assert_equal :pass, report.check(:sync_round_trip).status
    assert SolidObjects::Process.exists?(id: existing_record.id),
      "doctor deleted the caller process the application already registered"
    assert_equal "running", existing_record.reload.shutdown_state
    assert_empty SolidObjects::Instance.where(actor_type: "solid_objects_doctor")
  ensure
    SolidObjects.reset_caller_process!
  end

  test "reports a failed round trip instead of raising while the database stays locked" do
    skip unless SolidObjects::Record.connection.adapter_name.match?(/sqlite/i)
    lock = hold_sqlite_write_lock

    report = with_immediate_sqlite_lock_failure { SolidObjects::Doctor.new.call }

    refute report.healthy?
    assert_equal :fail, report.check(:sync_round_trip).status
    assert_match(/database is locked/, report.check(:sync_round_trip).message)
  ensure
    release_sqlite_write_lock(lock) if lock
  end

  test "warns when probe records outlive a passing round trip" do
    doctor = SolidObjects::Doctor.new
    doctor.define_singleton_method(:delete_probe_actor) { |_actor_id| false }

    report = doctor.call

    assert report.healthy?
    assert_equal :warn, report.check(:sync_round_trip).status
    assert_match(/probe actor/, report.check(:sync_round_trip).message)
  end

  test "warns when every policy denies a neutral context without changing policies" do
    deny = ->(**) { false }
    SolidObjects.configuration.authorize_message = deny
    SolidObjects.configuration.authorize_query = deny
    SolidObjects.configuration.authorize_destroy = deny
    SolidObjects.configuration.authorize_subscription = deny
    SolidObjects.configuration.authorize_administration = deny

    report = SolidObjects::Doctor.new.call

    assert report.healthy?
    assert_equal :warn, report.check(:authorization).status
    assert_match(/all five policies denied/, report.check(:authorization).message)
    refute SolidObjects.configuration.authorize_message.call
    refute SolidObjects.configuration.authorize_query.call
    refute SolidObjects.configuration.authorize_destroy.call
  end

  test "warns when a sensitive policy allows a neutral context" do
    SolidObjects.configuration.authorize_subscription = ->(**) { true }

    report = SolidObjects::Doctor.new.call

    assert report.healthy?
    assert_equal :warn, report.check(:authorization).status
    assert_match(/authorize_destroy/, report.check(:authorization).message)
    assert_match(/authorize_subscription/, report.check(:authorization).message)
  end

  test "fails when the installed schema is incomplete" do
    connection = Object.new
    connection.define_singleton_method(:data_sources) { [] }

    report = SolidObjects::Doctor.new(connection:).call

    refute report.healthy?
    assert_equal :fail, report.check(:schema).status
    assert_match(/missing tables/, report.check(:schema).message)
    assert_equal :skip, report.check(:sync_round_trip).status
  end

  test "reports live runtime roles" do
    now = SolidObjects.database_adapter.database_now
    SolidObjects::Process.create!(
      id: SecureRandom.uuid,
      kind: "worker",
      hostname: "test-host",
      pid: ::Process.pid,
      started_at: now,
      last_heartbeat_at: now,
      metadata: {}
    )

    report = SolidObjects::Doctor.new.call

    assert_equal :pass, report.check(:runtime).status
    assert_match(/worker=1/, report.check(:runtime).message)
  end

  test "registers a Rails doctor task" do
    original_application = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/tasks/solid_objects_tasks.rake", __dir__)

    output, = capture_io { Rake::Task["solid_objects:doctor"].invoke }

    assert_includes output, "Solid Objects doctor"
    assert_includes output, "sync_round_trip"
  ensure
    Rake.application = original_application
  end

  private

  def hold_sqlite_write_lock
    locked = Queue.new
    release = Queue.new
    thread = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do
        SolidObjects::Record.transaction do
          SolidObjects::Process.create!(
            id: SecureRandom.uuid,
            kind: "lock-holder",
            hostname: "test-host",
            pid: ::Process.pid,
            started_at: Time.current,
            last_heartbeat_at: Time.current,
            metadata: {}
          )
          locked << true
          release.pop
        end
      end
    end
    Timeout.timeout(2) { locked.pop }
    [ thread, release ]
  end

  def release_sqlite_write_lock(lock)
    thread, release = lock
    release << true
    thread.join
  end
end
