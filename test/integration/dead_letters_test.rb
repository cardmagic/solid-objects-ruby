# frozen_string_literal: true

require "database_test_helper"

class DeadLettersTest < ActiveSupport::TestCase
  class PoisonActor < SolidObjects::Actor
    actor_type "dead-letter-poison"

    class << self
      attr_accessor :fail
    end

    def run
      raise "poison message" if self.class.fail
    end
  end

  setup do
    PoisonActor.fail = true
    SolidObjects.configuration.max_attempts = 1
    SolidObjects.configuration.retry_delay = ->(_attempt) { 0 }
  end

  test "requires administration authorization to inspect dead letters" do
    create_dead_letter
    SolidObjects.configuration.authorize_administration = ->(**) { false }

    assert_raises(SolidObjects::Unauthorized) do
      SolidObjects.dead_letters.all(authorization_context: "operator")
    end
  end

  test "retries a dead letter through the durable mailbox once" do
    dead_letter = create_dead_letter
    SolidObjects.configuration.authorize_administration = ->(**) { true }
    PoisonActor.fail = false

    first_reference = SolidObjects.dead_letters.retry(
      dead_letter.id,
      authorization_context: "operator"
    )
    second_reference = SolidObjects.dead_letters.retry(
      dead_letter.id,
      authorization_context: "operator"
    )

    assert_equal first_reference.id, second_reference.id
    assert_equal first_reference.id, dead_letter.reload.retried_message_id

    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal "completed", first_reference.status
  ensure
    worker&.stop
  end

  private

  def create_dead_letter
    PoisonActor.ref("one").run
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    SolidObjects::DeadLetter.first
  ensure
    worker&.stop
  end
end
