# rbs_inline: enabled

module SolidObjects
  ErrorRecord = Data.define(:class_name, :message, :backtrace) do
    # @rbs (Hash[String, untyped]?) -> ErrorRecord?
    def self.from(error)
      return nil if error.blank?

      new(
        class_name: error["class"],
        message: error["message"],
        backtrace: Array(error["backtrace"]).freeze
      )
    end
  end

  RejectionRecord = Data.define(:code, :message, :details) do
    # @rbs (Hash[String, untyped]?) -> RejectionRecord?
    def self.from(rejection)
      return nil if rejection.blank?

      new(
        code: rejection["code"],
        message: rejection["message"],
        details: Serialization.readonly_copy(rejection["details"])
      )
    end
  end

  Outcome = Data.define(:status, :result, :error, :rejection, :attempts)
end
