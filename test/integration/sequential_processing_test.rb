# frozen_string_literal: true

require "database_test_helper"
require "timeout"

class SequentialProcessingTest < ActiveSupport::TestCase
  class BlockingActor < SolidObjects::Actor
    actor_type "blocking"

    class << self
      attr_accessor :started, :release
    end

    attribute :values, default: -> { [] }

    def append(value:)
      self.class.started << actor_id
      self.class.release.pop
      values << value
    end
  end

  setup do
    BlockingActor.started = Queue.new
    BlockingActor.release = Queue.new
  end

  test "two workers never execute two messages for one actor together" do
    reference = BlockingActor.ref("same")
    reference.append(value: 1)
    reference.append(value: 2)
    first_worker = SolidObjects::Worker.new
    second_worker = SolidObjects::Worker.new

    first_thread = Thread.new { first_worker.run_once }
    assert_equal "same", Timeout.timeout(2) { BlockingActor.started.pop }

    assert_equal 0, second_worker.run_once

    BlockingActor.release << true
    assert_equal "same", Timeout.timeout(2) { BlockingActor.started.pop }
    BlockingActor.release << true
    first_thread.join

    assert_equal({ "values" => [ 1, 2 ] }, SolidObjects::Instance.find_by!(actor_id: "same").state)
  ensure
    first_worker&.stop
    second_worker&.stop
  end

  test "different actor identities execute concurrently" do
    BlockingActor.ref("alice").append(value: 1)
    BlockingActor.ref("bob").append(value: 2)
    first_worker = SolidObjects::Worker.new
    second_worker = SolidObjects::Worker.new

    threads = [
      Thread.new { first_worker.run_once },
      Thread.new { second_worker.run_once }
    ]
    started_actor_ids = 2.times.map { Timeout.timeout(2) { BlockingActor.started.pop } }

    assert_equal %w[alice bob], started_actor_ids.sort

    2.times { BlockingActor.release << true }
    threads.each(&:join)
  ensure
    first_worker&.stop
    second_worker&.stop
  end
end
