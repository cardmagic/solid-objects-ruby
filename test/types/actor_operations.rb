# rbs_inline: enabled

class SignatureParent < SolidObjects::Actor
  def recover_if_stuck(generation:)
    generation
  end
end

class SignatureChat < SignatureParent
  actor_type "signature-chat"
  attribute :generation, default: 1
  query(:status) { "running" }
  message :block_callback do |result:|
    # @type var result: String
    result
  end

  def start
    schedule(at: Time.now, key: "watchdog").recover_if_stuck(generation: 1)
    transmit.recover_if_stuck(generation: 1)
    schedule(at: Time.now).finish
    schedule(at: Time.now).optional
    schedule(at: Time.now).optional(generation: 1)
    schedule(at: Time.now).overloaded(value: "next")
    schedule(at: Time.now).overloaded(value: 1)
    transmit.echo(value: { "generation" => 1 })
    emit :run_model, on_success: "block_callback", on_failure: :fail_turn, generation: 1
    emit "another_effect", on_success: :finish, on_failure: "fail_turn"
    commit_action :global_action, generation: 1
    nil
  end

  def dynamic(operation:, callback:)
    schedule(at: Time.now).public_send(operation, generation: 1)
    public_send(:emit, :run_model, on_failure: callback, generation: 1)
    nil
  end

  def finish
    nil
  end

  def staged_result
    schedule(at: Time.now).echo(value: 1)
  end

  def echo(value:)
    value
  end

  def overloaded(value:)
    value
  end

  def optional(generation: 1)
    generation
  end

  def fail_turn(effect_id:, arguments:, error:)
    error["message"]
  end

  private

  def helper
    nil
  end
end
