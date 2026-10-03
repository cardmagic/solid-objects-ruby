# rbs_inline: enabled

class TelemetryConsumer
  def event_name(event)
    event["name"]
  end

  def wait_reason(event)
    event["attributes"]["waitingOn"]
  end

  def metric_names(event)
    event["metrics"].map { |metric| metric["name"] }
  end

  def oldest_mailbox_age(summary)
    summary["mailbox"]["oldestAgeMilliseconds"]
  end

  def observed_names(reference)
    names = [] #: Array[String]
    reference.observe(authorization_context: nil) { |event| names << event["name"] }
    names
  end
end
