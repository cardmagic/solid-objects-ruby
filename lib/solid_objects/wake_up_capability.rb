# rbs_inline: enabled

module SolidObjects
  WakeUpCapability = Data.define(:adapter, :crosses_processes, :measured_floor_ms, :reason)

  module ReportsWakeUpCapability
    # @rbs (WakeUpCapability) -> void
    attr_writer :capability

    # @rbs () -> WakeUpCapability
    def capability
      @capability ||= default_capability
    end
  end
end
