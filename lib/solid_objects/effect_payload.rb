# rbs_inline: enabled

module SolidObjects
  module EffectPayload
    class << self
      # @rbs [Arguments, Result] (effect_id: String, arguments: Arguments, result: Result) -> effect_success_payload[Arguments, Result]
      def success(effect_id:, arguments:, result:)
        { "effect_id" => effect_id, "arguments" => arguments, "result" => result }
      end

      # @rbs [Arguments] (effect_id: String, arguments: Arguments, error: effect_error) -> effect_failure_payload[Arguments]
      def failure(effect_id:, arguments:, error:)
        { "effect_id" => effect_id, "arguments" => arguments, "error" => error }
      end

      # @rbs (Exception) -> effect_error
      def error(exception)
        message = exception.message.to_s.byteslice(0, 8_192) # : String
        {
          "class" => exception.class.name,
          "message" => message,
          "backtrace" => Array(exception.backtrace).first(50)
        }
      end
    end
  end
end
