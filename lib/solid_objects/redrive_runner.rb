# rbs_inline: enabled

module SolidObjects
  # Moves dead rows back to pending for one redrive task at a time, in bounded
  # batches. Each batch is its own short transaction, so a redrive of thousands
  # of rows never holds a lock long enough to starve delivery.
  class RedriveRunner
    # @rbs () -> bool
    def run_once
      database_adapter.transaction do
        record = claim
        next false unless record

        advance(record)
      end
    end

    private

    # @rbs () -> Redrive?
    def claim
      Redrive.lock.where(status: RedriveManager::RUNNING).order(:started_at, :id).first
    end

    # @rbs (Redrive) -> bool
    def advance(record)
      moved = move_batch(record)
      return true if moved.positive?

      finish(record)
      false
    end

    # @rbs (Redrive) -> Integer
    def move_batch(record)
      scope = DeadLetterScope.for_kind(record.kind)
      size = batch_size(record)
      return 0 unless size.positive?

      identifiers = scope
        .matching(record.filters, dead_before: record.started_at)
        .order(:id)
        .limit(size)
        .pluck(:id)
      return 0 if identifiers.empty?

      revived = scope.revive_all(identifiers)
      record.update!(moved: record.moved + revived)
      revived
    end

    # @rbs (Redrive) -> Integer
    def batch_size(record)
      configured = SolidObjects.configuration.redrive_batch_size
      limit = record.move_limit
      return configured unless limit

      [ configured, limit - record.moved ].min
    end

    # @rbs (Redrive) -> void
    def finish(record)
      manager = SolidObjects.redrives
      manager.close(record, status: RedriveManager::COMPLETED)
      manager.audit(record, action: "redrive.finish")
    end

    # @rbs () -> DatabaseAdapter
    def database_adapter
      SolidObjects.database_adapter
    end
  end
end
