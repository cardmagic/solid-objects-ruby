# rbs_inline: enabled

module SolidObjects
  class Message < Record
    self.table_name = SolidObjects.table_name(:messages)

    belongs_to :instance, class_name: "SolidObjects::Instance", inverse_of: :messages
    has_one :ready_message,
      class_name: "SolidObjects::ReadyMessage",
      inverse_of: :message,
      dependent: :destroy
    has_one :claimed_message,
      class_name: "SolidObjects::ClaimedMessage",
      inverse_of: :message,
      dependent: :destroy
    has_one :dead_letter,
      class_name: "SolidObjects::DeadLetter",
      inverse_of: :message,
      dependent: :destroy

    before_validation :supply_defaults

    validates :delivery_mode, inclusion: { in: %w[async sync internal] }

    # @rbs () -> bool
    def ready?
      ready_message.present?
    end

    # @rbs () -> bool
    def claimed?
      claimed_message.present?
    end

    # @rbs () -> bool
    def completed?
      completed_at.present?
    end

    # @rbs () -> bool
    def rejected?
      rejected_at.present?
    end

    # @rbs () -> bool
    def dead?
      dead_letter.present?
    end

    private

    # @rbs () -> void
    def supply_defaults
      self.arguments ||= {}
      self.available_at ||= enqueued_at || Time.current
    end
  end
end
