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

  test "a running effect keeps its process heartbeat fresh" do
    SolidObjects.configuration.process_heartbeat_interval = 0.02
    SolidObjects.configuration.process_alive_threshold = 0.1
    ExportActor.ref("long-handler").async.start_recoverable_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    entered = Queue.new
    release = Queue.new
    heartbeats = Queue.new
    executing = nil
    registry = SolidObjects::ProcessRegistry.new
    registry.define_singleton_method(:heartbeat) do
      updated = super()
      heartbeats << Thread.current if updated && executing
      updated
    end
    SolidObjects.register_effect(:build_report) do
      executing = Thread.current
      entered << true
      release.pop
      { "artifact_key" => "report.pdf" }
    end
    executor = SolidObjects::EffectExecutor.new(process_registry: registry)
    effect_thread = Thread.new do
      SolidObjects::Record.connection_pool.with_connection { executor.run_once }
    end
    Timeout.timeout(5) { entered.pop }
    heartbeat_thread = Timeout.timeout(2) { heartbeats.pop }
    Timeout.timeout(2) { 7.times { heartbeats.pop } }
    SolidObjects::EffectRecoveryCoordinator.new.recover_available
    assert_equal "processing", SolidObjects::Effect.find_by!(name: "build_report").status
    assert_empty SolidObjects::Message.where(operation: "retired")
    release << true
    assert effect_thread.value
    refute heartbeat_thread.alive?
    assert_equal "completed", SolidObjects::Effect.find_by!(name: "build_report").status
  ensure
    release&.push(true)
    effect_thread&.join(5)
    executor&.stop
    worker&.stop
  end

  test "a failed handler stops its heartbeat before scheduling a retry" do
    SolidObjects.configuration.process_heartbeat_interval = 0.01
    ExportActor.ref("failing-handler").async.start_recoverable_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    heartbeats = Queue.new
    registry = SolidObjects::ProcessRegistry.new
    registry.define_singleton_method(:heartbeat) do
      updated = super()
      heartbeats << Thread.current if updated
      updated
    end
    heartbeat_thread = nil
    SolidObjects.register_effect(:build_report) do
      heartbeats.pop(true) until heartbeats.empty?
      heartbeat_thread = Timeout.timeout(2) { heartbeats.pop }
      raise "remote request failed"
    end
    executor = SolidObjects::EffectExecutor.new(process_registry: registry)
    refute executor.run_once
    refute_nil heartbeat_thread
    refute heartbeat_thread.alive?
    assert_equal "pending", SolidObjects::Effect.find_by!(name: "build_report").status
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    executor&.stop
    worker&.stop
  end

  test "heartbeat maintenance resumes after a database error" do
    SolidObjects.configuration.process_heartbeat_interval = 0.01
    registry = SolidObjects::ProcessRegistry.new
    registry.register(kind: "effect")
    resumed = Queue.new
    attempts = 0
    registry.define_singleton_method(:heartbeat) do
      attempts += 1
      if attempts == 1
        SolidObjects::Record.connection.select_value("SELECT absent_heartbeat_column FROM #{SolidObjects.table_name(:processes)}")
      end
      updated = super()
      resumed << true if updated
      updated
    end
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("solid_objects.process.heartbeat_failed") { |event| events << event.payload }
    heartbeat = SolidObjects::ProcessHeartbeat.new(process_registry: registry)
    heartbeat.start
    Timeout.timeout(2) { resumed.pop }
    heartbeat.stop
    assert_operator attempts, :>=, 2
    assert_equal 1, events.length
    assert_equal registry.process_record.id, events.first.fetch(:process_id)
  ensure
    heartbeat&.stop
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    registry&.stop
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

  test "one remaining mailbox slot cannot partially commit retirement" do
    worker, effect_executor, effect = processing_export("full-mailbox")
    original_limit = SolidObjects.configuration.max_mailbox_length
    SolidObjects.configuration.max_mailbox_length = 1
    assert_raises(SolidObjects::MailboxFull) do
      SolidObjects.database_adapter.transaction do
        instance = SolidObjects::Instance.lock.find(effect.instance_id)
        SolidObjects::EffectRecoveryCoordinator.new.check(instance:, intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id: "full") ])
      end
    end
    assert_equal "processing", effect.reload.status
    assert_nil SolidObjects::EffectRecovery.find(effect.effect_id).retired_at
    assert_empty SolidObjects::Message.where(operation: [ "retired", "checked" ])
  ensure
    SolidObjects.configuration.max_mailbox_length = original_limit if original_limit
    effect_executor&.stop
    worker&.stop
  end

  test "runtime floor changes and missing owners are rechecked for existing effects" do
    worker, effect_executor, effect = processing_export("runtime-floor")
    SolidObjects::EffectRecovery.find(effect.effect_id).update!(recovery_timeout: 1)
    SolidObjects::Process.find(effect.claimed_by).update!(last_heartbeat_at: SolidObjects.database_adapter.database_clock_now - 70)
    SolidObjects.configuration.process_alive_threshold = 120
    SolidObjects::EffectRecoveryCoordinator.new.recover_available
    assert_equal "processing", effect.reload.status
    assert_empty SolidObjects::Message.where(operation: "retired")
    effect.update!(claimed_by: nil)
    SolidObjects::EffectRecoveryCoordinator.new.recover_available
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "database time lookup failure rolls back without an abandonment outcome" do
    worker, effect_executor, effect = processing_export("lookup-error")
    adapter = SolidObjects.database_adapter
    adapter.define_singleton_method(:database_clock_now) do
      SolidObjects::Record.connection.select_value("SELECT absent_recovery_column FROM #{SolidObjects.table_name(:processes)}")
    end
    assert_raises(ActiveRecord::StatementInvalid) { SolidObjects::EffectRecoveryCoordinator.new.recover_available }
    assert_equal "processing", effect.reload.status
    assert_nil SolidObjects::EffectRecovery.find(effect.effect_id).retired_at
    assert_empty SolidObjects::Message.where(operation: [ "retired", "checked" ])
  ensure
    adapter&.singleton_class&.remove_method(:database_clock_now)
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

  test "pending work does not wait on a recovery candidate within its extended grace" do
    skip "PostgreSQL independent claims" unless database_family == :postgresql

    worker, effect_executor, effect = processing_export("fresh-candidate")
    SolidObjects::EffectRecovery.find(effect.effect_id).update!(recovery_timeout: 120)
    SolidObjects::Process.find(effect.claimed_by).update!(last_heartbeat_at: SolidObjects.database_adapter.database_clock_now - 75)
    ExportActor.ref("other").async.start_export
    worker.run_until_idle
    claimant = SolidObjects::EffectExecutor.new
    results = Queue.new
    claim_thread = nil
    SolidObjects.database_adapter.transaction do
      SolidObjects::Instance.lock.find(effect.instance_id)
      claim_thread = Thread.new do
        SolidObjects::Record.connection_pool.with_connection do
          results << claimant.send(:claim_next)
        end
      end
      selected = Timeout.timeout(2) { results.pop }
      assert_equal "other", selected.instance.actor_id
    end
  ensure
    claim_thread&.join(5)
    claimant&.stop
    effect_executor&.stop
    worker&.stop
  end

  test "recovery notification survives a process crash after retirement" do
    worker, effect_executor, effect = processing_export("crash")
    worker.stop
    configuration = SolidObjects::Record.connection_db_config.configuration_hash
    script = <<~RUBY
      require "solid_objects"
      ActiveRecord::Base.establish_connection(JSON.parse(ENV.fetch("RECOVERY_DATABASE_CONFIGURATION")))
      %w[record process instance message ready_message claimed_message reminder effect effect_recovery broadcast dead_letter].each do |model|
        require File.expand_path("app/models/solid_objects/\#{model}")
      end
      class RecoveryExport < SolidObjects::Actor
        actor_type "effect-recovery-export"
        def retired(effect_id:, arguments:, outcome:)
        end
      end
      SolidObjects::EffectRecoveryCoordinator.new.recover_available
      ::Process.kill("KILL", ::Process.pid)
    RUBY
    process_id = ::Process.spawn({ "RECOVERY_DATABASE_CONFIGURATION" => JSON.generate(configuration) }, Gem.ruby, "-Ilib", "-e", script)
    _, status = ::Process.wait2(process_id)
    assert status.signaled?
    assert_equal Signal.list.fetch("KILL"), status.termsig
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
    assert_empty effect.instance.reload.state.fetch("notifications")
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    assert_equal 1, effect.instance.reload.state.fetch("notifications").length
    assert_nil effect_executor.send(:claim_next)
  ensure
    effect_executor&.stop
    worker&.stop
  end

  test "a pending claimant wins before the explicit check and is rechecked" do
    skip "PostgreSQL independent claims" unless database_family == :postgresql

    ExportActor.ref("claim-first").async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect = SolidObjects::Effect.find_by!(name: "build_report")
    claimant = SolidObjects::EffectExecutor.new
    adapter = SolidObjects.database_adapter
    original_lock = adapter.method(:lock_candidates)
    locked = Queue.new
    release = Queue.new
    results = Queue.new
    origin_locked = Queue.new
    adapter.define_singleton_method(:lock_candidates) do |scope|
      relation = original_lock.call(scope).load
      locked << true
      release.pop
      relation
    end
    claim_thread = Thread.new do
      SolidObjects::Record.connection_pool.with_connection { results << claimant.send(:claim_next) }
    end
    Timeout.timeout(5) { locked.pop }
    check_thread = Thread.new do
      SolidObjects::Record.connection_pool.with_connection do
        SolidObjects.database_adapter.transaction do
          instance = SolidObjects::Instance.lock.find(effect.instance_id)
          origin_locked << true
          SolidObjects::EffectRecoveryCoordinator.new.check(instance:, intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id: "claim-first") ])
        end
      end
    end
    Timeout.timeout(5) { origin_locked.pop }
    release << true
    assert_equal effect.id, Timeout.timeout(5) { results.pop }.id
    check_thread.join(5)
    assert_equal "deferred", SolidObjects::Message.find_by!(operation: "checked").arguments.fetch("outcome")
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    release&.push(true)
    claim_thread&.join(5)
    check_thread&.join(5)
    adapter&.singleton_class&.remove_method(:lock_candidates)
    claimant&.stop
    worker&.stop
  end

  test "an explicit check can win and leave pending work for the claimant" do
    skip "PostgreSQL independent claims" unless database_family == :postgresql

    ExportActor.ref("check-first").async.start_checked_export
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    effect = SolidObjects::Effect.find_by!(name: "build_report")
    claimant = SolidObjects::EffectExecutor.new
    results = Queue.new
    claim_thread = nil
    SolidObjects.database_adapter.transaction do
      instance = SolidObjects::Instance.lock.find(effect.instance_id)
      SolidObjects::EffectRecoveryCoordinator.new.check(instance:, intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id: "check-first") ])
      claim_thread = Thread.new do
        SolidObjects::Record.connection_pool.with_connection { results << claimant.send(:claim_next) }
      end
      assert_nil Timeout.timeout(5) { results.pop }
    end
    assert_equal effect.id, claimant.send(:claim_next).id
    assert_equal "pending", SolidObjects::Message.find_by!(operation: "checked").arguments.fetch("outcome")
    assert_empty SolidObjects::Message.where(operation: "retired")
  ensure
    claim_thread&.join(5)
    claimant&.stop
    worker&.stop
  end

  test "concurrent explicit checks and a replay share one retirement" do
    skip "PostgreSQL independent checks" unless database_family == :postgresql

    worker, effect_executor, effect = processing_export("explicit-race")
    process_ids = Queue.new
    check = ->(request_id) do
      SolidObjects.database_adapter.transaction do
        instance = SolidObjects::Instance.lock.find(effect.instance_id)
        SolidObjects::EffectRecoveryCoordinator.new.check(instance:, intents: [ SolidObjects::Actor::EffectRecoveryIntent.new(effect_id: effect.effect_id, request_id:) ])
      end
    end
    threads = []
    SolidObjects.database_adapter.transaction do
      SolidObjects::Instance.lock.find(effect.instance_id)
      %w[one two].each do |request_id|
        threads << Thread.new do
          SolidObjects::Record.connection_pool.with_connection do |connection|
            process_ids << connection.select_value("SELECT pg_backend_pid()").to_i
            check.call(request_id)
          end
        end
      end
      2.times { wait_for_blocked_process(Timeout.timeout(5) { process_ids.pop }) }
    end
    threads.each { |thread| thread.join(5) }
    check.call("one")
    assert_equal 1, SolidObjects::Message.where(operation: "retired").count
    assert_equal %w[retired already_retired], SolidObjects::Message.where(operation: "checked").order(:sequence).map { |message| message.arguments.fetch("outcome") }
  ensure
    threads&.each { |thread| thread.join(5) }
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
