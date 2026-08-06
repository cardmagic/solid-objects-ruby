# frozen_string_literal: true

require "database_test_helper"

class RetryTest < ActiveSupport::TestCase
  class RetryingActor < SolidObjects::Actor
    actor_type "retrying"

    attribute :executions, default: 0

    def run
      self.executions += 1
      raise "first attempt" if current_message.attempt == 1

      executions
    end
  end

  class PoisonActor < SolidObjects::Actor
    actor_type "poison"

    attribute :processed, default: -> { [] }

    def poison
      processed << "failed"
      raise "poison"
    end

    def continue_processing
      processed << "continued"
    end
  end

  setup do
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
  end

  test "redelivers a failed handler with the previously committed state" do
    message_reference = RetryingActor.ref("one").run
    worker = SolidObjects::Worker.new

    assert_equal 2, worker.run_until_idle

    message = SolidObjects::Message.find(message_reference.id)
    assert_equal 2, message.attempt_count
    assert message.completed?
    assert_nil message.result
    assert_equal({ "executions" => 1 }, message.instance.state)
  ensure
    worker&.stop
  end

  test "dead-letters a poison message before continuing the mailbox" do
    SolidObjects.configuration.max_attempts = 2
    reference = PoisonActor.ref("one")
    failed_message = reference.poison
    continued_message = reference.continue_processing
    worker = SolidObjects::Worker.new

    assert_equal 3, worker.run_until_idle

    assert_equal "dead", failed_message.status
    assert_equal "completed", continued_message.status
    assert_equal 1, SolidObjects::DeadLetter.count
    assert_equal({ "processed" => [ "continued" ] }, SolidObjects::Instance.find_by!(actor_type: "poison").state)
  ensure
    worker&.stop
  end
end
