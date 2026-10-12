# rbs_inline: enabled

require "database_test_helper"
require "timeout"

class CallerLifecycleTest < ActiveSupport::TestCase
  class BlockingWakeUp
    # @rbs @waiting: Thread::Queue
    # @rbs @release: Thread::Queue

    attr_reader :waiting, :release

    # @rbs () -> void
    def initialize
      @waiting = Queue.new
      @release = Queue.new
    end

    # @rbs () -> void
    def signal
    end

    # @rbs (timeout: Numeric) -> void
    def wait(timeout:)
      waiting << timeout
      release.pop
    end
  end

  class Counter < SolidObjects::Actor
    actor_type "caller-lifecycle-counter"
    attribute :count, default: 0

    class << self
      attr_accessor :started, :release
    end

    # @rbs (label: String) -> Integer
    def increment(label:)
      self.count += 1
      emit(:caller_effect, label:)
      if self.class.started
        self.class.started << label
        self.class.release.pop
      end
      count
    end
  end

  setup do
    SolidObjects.configuration.max_attempts = 1
  end

  teardown do
    Counter.started = nil
    Counter.release = nil
  end

  test "concurrent callers preserve staged effects and ordered state" do
    Counter.started = Queue.new
    Counter.release = Queue.new
    wake_up = BlockingWakeUp.new
    SolidObjects.configuration.wake_up_adapter = wake_up
    reference = Counter.ref("concurrent")

    first = Thread.new { reference.increment(label: "first") }
    assert_equal "first", Timeout.timeout(10) { Counter.started.pop }
    second = Thread.new { reference.increment(label: "second") }
    Timeout.timeout(10) { wake_up.waiting.pop }
    assert_raises(ThreadError) { Counter.started.pop(true) }
    assert_equal 1, SolidObjects::ClaimedMessage.count
    assert_equal 1, SolidObjects::ReadyMessage.count
    assert_empty SolidObjects::Effect.all
    Counter.release << true
    assert_equal 1, Timeout.timeout(10) { first.value }
    wake_up.release << true
    assert_equal "second", Timeout.timeout(10) { Counter.started.pop }
    Counter.release << true
    assert_equal 2, Timeout.timeout(10) { second.value }

    instance = SolidObjects::Instance.find_by!(actor_type: Counter.actor_type, actor_id: "concurrent")
    assert_equal({ "count" => 2 }, instance.state)
    assert_equal [ "first", "second" ], SolidObjects::Effect.all.map { |effect| effect.arguments.fetch("label") }.sort
    assert_equal [ 1, 1 ], SolidObjects::Message.order(:sequence).pluck(:attempt_count)
    assert_empty SolidObjects::ClaimedMessage.all
    assert_empty SolidObjects::DeadLetter.all
  ensure
    Counter.release << true if first&.alive?
    Counter.release << true if second&.alive?
    wake_up&.release&.push(true) if second&.alive?
    first&.join(10)
    second&.join(10)
  end

  test "caller re-registers after stale cleanup and process retention" do
    reference = Counter.ref("retained-process")
    assert_equal 1, reference.increment(label: "before")
    original_process = SolidObjects.caller_process.process_registry.process_record
    original_process.update!(last_heartbeat_at: 2.minutes.ago)
    assert_equal 1, SolidObjects::ProcessRegistry.cleanup_dead
    assert_equal "stopped", original_process.reload.shutdown_state

    assert_equal 2, reference.increment(label: "after-cleanup")
    stopped_process = SolidObjects.caller_process.process_registry.process_record
    refute_equal original_process.id, stopped_process.id
    assert_equal "running", stopped_process.shutdown_state
    stopped_process.update!(last_heartbeat_at: 2.minutes.ago)
    assert_equal 1, SolidObjects::ProcessRegistry.cleanup_dead
    SolidObjects::Process.where(id: [ original_process.id, stopped_process.id ]).update_all(stopped_at: 8.days.ago)
    assert_equal 2, SolidObjects::ProcessPruner.new.prune
    refute SolidObjects::Process.exists?(stopped_process.id)

    assert_equal 3, reference.increment(label: "after-retention")
    replacement = SolidObjects.caller_process.process_registry.process_record
    refute_equal stopped_process.id, replacement.id
    assert_equal "running", replacement.shutdown_state
    assert_equal [ 1, 1, 1 ], SolidObjects::Message.order(:sequence).pluck(:attempt_count)
    assert_empty SolidObjects::DeadLetter.all
  end
end
