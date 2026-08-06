# frozen_string_literal: true

require "database_test_helper"

class ActorCommunicationTest < ActiveSupport::TestCase
  class TargetActor < SolidObjects::Actor
    actor_type "communication-target"

    attribute :values, default: -> { [] }

    def receive(value:)
      values << value
    end
  end

  class SourceActor < SolidObjects::Actor
    actor_type "communication-source"

    def send_value(target_id:, value:)
      TargetActor.ref(target_id).receive(value:)
    end
  end

  test "stages actor-to-actor tell in the source commit" do
    SourceActor.ref("source").send_value(target_id: "target", value: 42)
    worker = SolidObjects::Worker.new
    worker.run_until_idle

    assert_equal 1, SolidObjects::Effect.where(name: "__actor_message__", status: "pending").count
    assert_nil SolidObjects::Instance.find_by(actor_type: "communication-target")

    effect_executor = SolidObjects::EffectExecutor.new
    effect_executor.run_once
    worker.run_until_idle

    assert_equal(
      { "values" => [ 42 ] },
      SolidObjects::Instance.find_by!(actor_type: "communication-target", actor_id: "target").state
    )
  ensure
    effect_executor&.stop
    worker&.stop
  end
end
