# rbs_inline: enabled

class EffectPayloadConsumer < SolidObjects::Actor
  def recovery_result(payload)
    return payload["result"] if payload["outcome"] == SolidObjects::EffectRecoveryOutcome::COMPLETED

    nil
  end

  def retired(arguments)
    { "effect_id" => "effect-1", "arguments" => arguments, "outcome" => SolidObjects::EffectRecoveryOutcome::RETIRED }
  end

  def completed_recovery(arguments)
    { "effect_id" => "effect-1", "arguments" => arguments, "outcome" => SolidObjects::EffectRecoveryOutcome::COMPLETED, "result" => nil }
  end

  def retired_revision(payload)
    payload["arguments"]["revision"]
  end

  def retired_outcome
    SolidObjects::EffectRecoveryOutcome::RETIRED
  end

  def fail_turn(effect_id:, arguments:, error:)
    arguments["generation"]
  end

  def success_value(payload)
    payload["result"]
  end

  def error_message(payload)
    payload["error"]["message"]
  end

  def error_class(payload)
    payload["error"]["class"]
  end

  def error_backtrace(payload)
    payload["error"]["backtrace"]
  end

  def failure(arguments)
    {
      "effect_id" => "effect-1",
      "arguments" => arguments,
      "error" => { "class" => "Error", "message" => "failed", "backtrace" => [] }
    }
  end
end
