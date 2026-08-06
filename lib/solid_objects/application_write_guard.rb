# rbs_inline: enabled

module SolidObjects
  class ApplicationWriteGuard
    class << self
      # @rbs (actor_type: String, actor_id: String, operation: String) { () -> untyped } -> untyped
      def call(actor_type:, actor_id:, operation:)
        ActiveRecord::Base.while_preventing_writes { yield }
      rescue ActiveRecord::ReadOnlyError
        SolidObjects.instrument(
          :"actor_code.write_forbidden",
          actor_type:,
          actor_id:,
          operation:
        )
        raise ApplicationWriteForbidden.new(
          actor_type:,
          actor_id:,
          message_name: operation
        )
      end
    end
  end
end
