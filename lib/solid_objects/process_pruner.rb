# rbs_inline: enabled

module SolidObjects
  class ProcessPruner
    # @rbs @now: Time
    # @rbs @batch_size: Integer

    # @rbs (?now: Time, ?batch_size: Integer) -> void
    def initialize(
      now: SolidObjects.database_adapter.database_now,
      batch_size: SolidObjects.configuration.prune_batch_size
    )
      @now = now
      @batch_size = batch_size
    end

    # @rbs () -> Integer
    def preview
      prunable.count
    end

    # @rbs () -> Integer
    def prune
      deleted = 0

      loop do
        process_ids = prunable.limit(batch_size).pluck(:id)
        break if process_ids.empty?

        deleted += Process.where(id: process_ids).delete_all
      end

      SolidObjects.instrument(:"processes.pruned", count: deleted)
      deleted
    end

    private

    attr_reader :now, :batch_size

    # @rbs () -> ActiveRecord::Relation[Process]
    def prunable
      Process.where(
        shutdown_state: "stopped",
        stopped_at: ...(now - SolidObjects.configuration.process_retention)
      )
    end
  end
end
