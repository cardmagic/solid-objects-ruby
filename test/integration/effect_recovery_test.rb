# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class EffectRecoveryTest < ActiveSupport::TestCase
  class ExportActor < SolidObjects::Actor
    actor_type "effect-recovery-export"
    attribute :effect_handle, default: nil
    attribute :notifications, default: -> { [] }

    def start_export
      self.effect_handle = emit(:build_report, revision: 1)
    end

    def start_recoverable_export
      self.effect_handle = emit(:build_report, revision: 1, on_recovery: :retired)
    end

    def retired(effect_id:, arguments:, outcome:)
      self.notifications += [ { "effect_id" => effect_id, "arguments" => arguments, "outcome" => outcome } ]
    end

    def start_checked_export
      self.effect_handle = emit(:build_report, revision: 1, on_recovery: :retired, on_status: :checked, on_success: :completed)
    end

    def start_with_timeout(timeout:)
      self.effect_handle = emit(:build_report, revision: 1, on_recovery: :retired, on_status: :checked, recovery_timeout: timeout)
    end

    def completed(effect_id:, arguments:, result:)
      self.notifications += [ { "effect_id" => effect_id, "result" => result } ]
    end

    def check_export
      request_effect_recovery(effect_handle)
    end

    def checked(effect_id:, outcome:, arguments: nil, result: nil)
      self.notifications += [ { "effect_id" => effect_id, "outcome" => outcome } ]
    end
  end

  test "emit returns the persisted public effect identity" do
    reference = ExportActor.ref("export")
    reference.async.start_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    effect = SolidObjects::Effect.find_by!(name: "build_report")
    assert_equal({ "effect_id" => effect.effect_id }, effect.instance.state.fetch("effect_handle"))
  ensure
    worker&.stop
  end

  test "false is not a recovery timeout" do
    actor = ExportActor.new(actor_id: "invalid", state: SolidObjects::State.new(ExportActor.definition.state_definition))
    assert_raises(ArgumentError) { actor.start_with_timeout(timeout: false) }
    assert_empty actor.send(:drain_effect_intents)
  end

  test "a longer recovery timeout survives ordinary process cleanup" do
    ExportActor.ref("long-grace").async.start_with_timeout(timeout: 120)
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new
    effect = effect_executor.send(:claim_next)
    owner = SolidObjects::Process.find(effect.claimed_by)
    owner.update!(last_heartbeat_at: SolidObjects.database_adapter.database_clock_now - 75)

    SolidObjects::ProcessRegistry.cleanup_dead

    assert_equal "processing", effect.reload.status
    assert_equal owner.id, effect.claimed_by
    assert_empty SolidObjects::Message.where(operation: "retired")
    owner.update!(stopped_at: Time.at(0))
    SolidObjects::ProcessPruner.new.prune
    assert SolidObjects::Process.exists?(owner.id)
    assert_nil effect_executor.send(:claim_next)
    owner.update!(last_heartbeat_at: SolidObjects.database_adapter.database_clock_now - 125)
    assert_nil effect_executor.send(:claim_next)
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "explicit checks distinguish completed dead missing and already retired effects" do
    reference = ExportActor.ref("outcomes")
    reference.async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect = SolidObjects::Effect.find_by!(name: "build_report")
    coordinator = SolidObjects::EffectRecoveryCoordinator.new
    check = -> do
      SolidObjects.database_adapter.transaction do
        instance = SolidObjects::Instance.lock.find(effect.instance_id)
        coordinator.check(instance:, intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id: SecureRandom.uuid) ])
      end
      SolidObjects::Message.where(operation: "checked").order(:sequence).last.arguments
    end

    effect.update!(status: "completed", result: nil)
    payload = check.call
    assert_equal "completed", payload.fetch("outcome")
    assert_nil payload.fetch("result")
    assert_equal({ "revision" => 1 }, payload.fetch("arguments"))
    effect.update!(status: "dead")
    assert_equal "dead", check.call.fetch("outcome")
    effect.destroy!
    assert_equal "missing", check.call.fetch("outcome")
    SolidObjects::EffectRecovery.find(effect.effect_id).update!(retired_at: Time.now.utc)
    assert_equal "already_retired", check.call.fetch("outcome")
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    worker&.stop
  end

  test "rollback undoes retirement and both callback messages" do
    ExportActor.ref("rollback").async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new
    effect = effect_executor.send(:claim_next)
    SolidObjects::Process.find(effect.claimed_by).update!(last_heartbeat_at: Time.at(0))

    SolidObjects.database_adapter.transaction do
      instance = SolidObjects::Instance.lock.find(effect.instance_id)
      SolidObjects::EffectRecoveryCoordinator.new.check(instance:, intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id: SecureRandom.uuid) ])
      raise ActiveRecord::Rollback
    end

    assert_equal "processing", effect.reload.status
    assert_nil SolidObjects::EffectRecovery.find(effect.effect_id).retired_at
    assert_empty SolidObjects::Message.where(operation: [ "retired", "checked" ])
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "cleanup retires abandoned opted-in effects and delivers one durable notification" do
    ExportActor.ref("abandoned").async.start_recoverable_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new
    effect = effect_executor.send(:claim_next)
    process = SolidObjects::Process.find(effect.claimed_by)
    process.update!(last_heartbeat_at: SolidObjects.database_adapter.database_now - 70)

    SolidObjects::ProcessRegistry.cleanup_dead

    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
    assert_nil effect_executor.send(:claim_next)
    worker.run_until_idle
    assert_equal [ { "effect_id" => effect.effect_id, "arguments" => { "revision" => 1 }, "outcome" => "retired" } ],
      effect.instance.reload.state.fetch("notifications")
    SolidObjects::ProcessRegistry.cleanup_dead
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "an explicit pending check delivers status without retiring or changing attempts" do
    reference = ExportActor.ref("checked")
    reference.async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect = SolidObjects::Effect.find_by!(name: "build_report")

    reference.async.check_export
    worker.run_until_idle

    assert_equal [ { "effect_id" => effect.effect_id, "outcome" => "pending" } ],
      effect.instance.reload.state.fetch("notifications")
    assert_equal "pending", effect.reload.status
    assert_equal 0, effect.attempt_count
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    worker&.stop
  end

  test "retirement and late completion share instance before effect lock order" do
    skip "PostgreSQL lock observation" unless database_family == :postgresql

    ExportActor.ref("lock-order").async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new
    effect = effect_executor.send(:claim_next)
    SolidObjects::Process.find(effect.claimed_by).update!(last_heartbeat_at: SolidObjects.database_adapter.database_now - 70)
    completion_pid = Queue.new
    completion_result = Queue.new
    completer = nil

    SolidObjects.database_adapter.transaction do
      instance = SolidObjects::Instance.lock.find(effect.instance_id)
      blocker_pid = SolidObjects::Record.connection.select_value("SELECT pg_backend_pid()").to_i
      completer = Thread.new do
        SolidObjects::Record.connection_pool.with_connection do |connection|
          completion_pid << connection.select_value("SELECT pg_backend_pid()").to_i
          begin
            effect_executor.send(:complete, effect, { "artifact_key" => "late" })
            completion_result << :completed
          rescue => error
            completion_result << error
          end
        end
      end
      pid = Timeout.timeout(5) { completion_pid.pop }
      Timeout.timeout(5) do
        until SolidObjects::Record.connection.select_value("SELECT #{blocker_pid} = ANY(pg_blocking_pids(#{pid}))")
          Thread.pass
        end
      end
      SolidObjects::EffectRecoveryCoordinator.new.check(
        instance:,
        intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id: SecureRandom.uuid) ]
      )
    end

    result = Timeout.timeout(5) { completion_result.pop }
    assert_instance_of SolidObjects::LostActivation, result
    assert SolidObjects::EffectRecovery.find(effect.effect_id).retired_at
    assert_equal [ "retired", "checked" ], SolidObjects::Message.where(operation: [ "retired", "checked" ]).order(:sequence).pluck(:operation)
  ensure
    completer&.join(5)
    effect_executor&.stop
    worker&.stop
  end

  test "recovery rechecks a heartbeat refreshed while waiting for its owner" do
    skip "PostgreSQL lock observation" unless database_family == :postgresql

    worker, effect_executor, effect = processing_export("refreshed")
    results = Queue.new
    process_ids = Queue.new
    recovery_thread = nil
    SolidObjects.database_adapter.transaction do
      owner = SolidObjects::Process.lock.find(effect.claimed_by)
      recovery_thread = spawn_recovery(results:, process_ids:)
      wait_for_blocked_process(Timeout.timeout(5) { process_ids.pop })
      owner.update!(last_heartbeat_at: SolidObjects.database_adapter.database_clock_now)
    end
    assert_equal :done, Timeout.timeout(5) { results.pop }
    assert_equal "processing", effect.reload.status
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    recovery_thread&.join(5)
    effect_executor&.stop
    worker&.stop
  end

  test "two blocked automatic recovery passes enqueue one callback" do
    skip "PostgreSQL lock observation" unless database_family == :postgresql

    worker, effect_executor, effect = processing_export("simultaneous")
    results = Queue.new
    process_ids = Queue.new
    recovery_threads = []
    SolidObjects.database_adapter.transaction do
      SolidObjects::Instance.lock.find(effect.instance_id)
      2.times { recovery_threads << spawn_recovery(results:, process_ids:) }
      2.times { wait_for_blocked_process(Timeout.timeout(5) { process_ids.pop }) }
    end
    2.times { assert_equal :done, Timeout.timeout(5) { results.pop } }
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
    worker.run_until_idle
    assert_equal 1, effect.instance.reload.state.fetch("notifications").length
  ensure
    recovery_threads&.each { |thread| thread.join(5) }
    effect_executor&.stop
    worker&.stop
  end

  test "late failure leaves retirement and the existing recovery callback intact" do
    worker, effect_executor, effect = processing_export("late-failure")
    SolidObjects::EffectRecoveryCoordinator.new.recover_available
    effect_executor.send(:fail_effect, effect, RuntimeError.new("late"))
    assert_equal "completed", effect.reload.status
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
    assert_empty SolidObjects::Message.where(operation: "completed")
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "a changed claimant is rechecked after the effect lock becomes available" do
    skip "PostgreSQL lock observation" unless database_family == :postgresql

    worker, effect_executor, effect = processing_export("new-claimant")
    replacement = SolidObjects::ProcessRegistry.new.register(kind: "effect")
    results = Queue.new
    process_ids = Queue.new
    recovery_thread = nil
    SolidObjects.database_adapter.transaction do
      SolidObjects::Instance.lock.find(effect.instance_id)
      locked = SolidObjects::Effect.lock.find(effect.id)
      recovery_thread = spawn_recovery(results:, process_ids:)
      wait_for_blocked_process(Timeout.timeout(5) { process_ids.pop })
      locked.update!(claimed_by: replacement.id)
    end
    assert_equal :done, Timeout.timeout(5) { results.pop }
    assert_equal replacement.id, effect.reload.claimed_by
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    recovery_thread&.join(5)
    effect_executor&.stop
    worker&.stop
  end

  private

  def processing_export(actor_id)
    ExportActor.ref(actor_id).async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect_executor = SolidObjects::EffectExecutor.new
    effect = effect_executor.send(:claim_next)
    SolidObjects::Process.find(effect.claimed_by).update!(last_heartbeat_at: Time.at(0))
    [ worker, effect_executor, effect ]
  end

  def spawn_recovery(results:, process_ids:)
    Thread.new do
      SolidObjects::Record.connection_pool.with_connection do |connection|
        process_ids << connection.select_value("SELECT pg_backend_pid()").to_i
        begin
          SolidObjects::EffectRecoveryCoordinator.new.recover_available
          results << :done
        rescue => error
          results << error
        end
      end
    end
  end

  def wait_for_blocked_process(process_id)
    Timeout.timeout(5) do
      until SolidObjects::Record.connection.select_value("SELECT cardinality(pg_blocking_pids(#{process_id})) > 0")
        Thread.pass
      end
    end
  end
end
