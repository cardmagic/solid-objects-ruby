# rbs_inline: enabled

class CustomerBillingSync < SolidObjects::Actor
  MAXIMUM_BACKOFF_MINUTES = 60

  attribute :last_synced_version, default: 0
  attribute :pending, default: -> { [] }
  attribute :pushing, default: false
  attribute :retry_count, default: 0
  attribute :next_retry_at, default: nil

  def update_subscription(version:, plan:)
    return newest_version if version <= newest_version

    self.pending = pending + [ { "version" => version, "plan" => plan, "key" => "billing-#{actor_id}-v#{version}" } ]
    push_next unless pushing || next_retry_at
    version
  end

  def pushed(effect_id:, arguments:, result:)
    self.pushing = false
    self.last_synced_version = arguments.fetch("version")
    self.pending = pending.drop(1)
    self.retry_count = 0
    self.next_retry_at = nil
    push_next
  end

  def push_failed(effect_id:, arguments:, error:)
    self.pushing = false
    self.retry_count += 1
    retry_at = [ 2**retry_count, MAXIMUM_BACKOFF_MINUTES ].min.minutes.from_now
    self.next_retry_at = retry_at.iso8601
    schedule(at: retry_at, key: "retry").retry_push
  end

  def retry_push
    self.next_retry_at = nil
    push_next unless pushing
  end

  private

  def newest_version
    pending.last&.fetch("version") || last_synced_version
  end

  def push_next
    update = pending.first
    return unless update

    self.pushing = true
    emit :push_subscription,
      idempotency_key: update.fetch("key"),
      customer_id: actor_id,
      version: update.fetch("version"),
      plan: update.fetch("plan"),
      on_success: :pushed,
      on_failure: :push_failed
  end
end
