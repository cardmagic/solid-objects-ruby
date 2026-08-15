# frozen_string_literal: true

require "web_test_helper"

class WebDeadLettersTest < WebTestCase
  class PoisonActor < SolidObjects::Actor
    actor_type "web-dead-letter-poison"

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
    @dead_letter = create_dead_letter
  end

  test "lists a dead letter with its exception" do
    response = get("/dead_letters")

    assert_equal 200, response.status
    assert_match(/web-dead-letter-poison/, response.body)
    assert_match(/RuntimeError/, response.body)
  end

  test "shows a dead letter with its backtrace" do
    response = get("/dead_letters/#{@dead_letter.id}")

    assert_equal 200, response.status
    assert_match(/poison message/, response.body)
    assert_match(/web_dead_letters_test/, response.body)
  end

  test "retries a dead letter through the authorized manager" do
    PoisonActor.fail = false

    response = post("/dead_letters/#{@dead_letter.id}/retry")

    assert_equal 302, response.status
    assert @dead_letter.reload.retried_message_id
  end

  test "retrying twice reuses the first retry message" do
    PoisonActor.fail = false

    post("/dead_letters/#{@dead_letter.id}/retry")
    first_message_id = @dead_letter.reload.retried_message_id
    post("/dead_letters/#{@dead_letter.id}/retry")

    assert_equal first_message_id, @dead_letter.reload.retried_message_id
  end

  # A class can be deleted while its dead letters outlive it. The operator who
  # presses Retry has to be told why nothing happened, rather than shown a bare
  # 500 from an exception that reached the Rack handler.
  test "reports a retry the runtime refuses rather than failing the page" do
    orphan = create_orphan_dead_letter

    response = post("/dead_letters/#{orphan.id}/retry")

    assert_equal 422, response.status
    assert_match(/web-retired-actor/, response.body)
    assert_match(/unknown actor type/, response.body)
    assert_nil orphan.reload.retried_message_id
  end

  test "refuses a retry the administration policy denies" do
    SolidObjects.configuration.authorize_administration = lambda do |action:, **|
      action != "retry"
    end

    response = post("/dead_letters/#{@dead_letter.id}/retry")

    assert_equal 403, response.status
    assert_nil @dead_letter.reload.retried_message_id
  end

  private

  def create_orphan_dead_letter
    instance = create_instance(actor_type: "web-retired-actor", actor_id: "gone")
    message = create_message(instance, operation: "checkout")
    now = SolidObjects.database_adapter.database_now
    SolidObjects::DeadLetter.create!(
      message:,
      instance:,
      actor_type: instance.actor_type,
      actor_id: instance.actor_id,
      operation: message.operation,
      arguments: message.arguments,
      attempts: 5,
      exception_class: "RuntimeError",
      exception_message: "gave up",
      backtrace: [],
      first_failed_at: now,
      last_failed_at: now
    )
  end

  def create_dead_letter
    PoisonActor.ref("one").async.run
    worker = SolidObjects::Worker.new
    worker.run_until_idle
    SolidObjects::DeadLetter.first
  ensure
    worker&.stop
  end
end
