# rbs_inline: enabled

module SolidObjects
  module Telemetry
    FIELDS = %w[
      activationGeneration activationOwnerId actorId actorType ageMilliseconds attempt broadcastId
      broadcastWorkers byteCount code commitAction component componentCount count currentIntervalMilliseconds
      deliveryMode depth durationMilliseconds effectId effectName effectWorkers errorName failureCount
      generation idlePollingIntervalMilliseconds incarnation instanceId intervalMilliseconds
      latenessMilliseconds messageId name nextRunAt occurrence operation outboxKind outcome ownerId payload
      phase pollingIntervalMilliseconds previousIntervalMilliseconds previousRunAt processId processKind
      reason reminderId reminderSchedulers requestId retryable revision role sequence status thresholdBytes
      timeoutMilliseconds truncated waitingOn workers
    ].freeze #: Array[String]
    ALIASES = {
      "errorClass" => "errorName",
      "stateRevision" => "revision",
      "durationMs" => "durationMilliseconds",
      "commitActionName" => "commitAction",
      "payloadName" => "payload"
    }.freeze #: Hash[String, String]

    class << self
      # @rbs (Effect | Broadcast) -> void
      def outbox(record)
        return unless SolidObjects.configuration.instrumentation || ActiveSupport::Notifications.notifier.listening?("solid_objects.outbox.age")

        instance = record.instance
        SolidObjects.instrument(
          :"outbox.age",
          instance_id: record.instance_id,
          actor_type: instance.actor_type,
          actor_id: instance.actor_id,
          message_id: record.message_id,
          attempt: record.attempt_count,
          outbox_kind: record.is_a?(Effect) ? "effect" : "broadcast",
          age_milliseconds: [ ((SolidObjects.database_adapter.database_now - record.available_at) * 1000).round, 0 ].max,
          **outbox_identity(record)
        )
      rescue
        nil
      end

      # @rbs (Symbol, Hash[Symbol, Object]) -> void
      def emit(name, payload)
        observer = SolidObjects.configuration.instrumentation
        return unless observer

        deliver(observer, event(name, payload))
      rescue
        nil
      end

      # @rbs (event_observer, portable_event) -> void
      def deliver(observer, event)
        observer.call(event)
      rescue => error
        log_delivery_failure(event.fetch("name"), error)
      end

      # @rbs (Symbol, Hash[Symbol, Object]) -> portable_event
      def event(name, payload)
        attributes = safe_attributes(payload)
        adapter = DatabaseAdapter.family(Record.connection).to_s
        event_name = "solid_objects.#{name}"
        labels = { "event" => event_name, "adapter" => adapter, "actorType" => attributes["actorType"].to_s }
        metrics = [ { "name" => "solid_objects.events", "kind" => "counter", "unit" => "1", "value" => 1, "labels" => labels } ]
        [
          [ "durationMilliseconds", "solid_objects.duration", "histogram", "ms" ],
          [ "latenessMilliseconds", "solid_objects.reminder.lateness", "histogram", "ms" ],
          [ "ageMilliseconds", "solid_objects.outbox.age", "histogram", "ms" ],
          [ "depth", "solid_objects.mailbox.depth", "gauge", "1" ]
        ].each do |field, metric, kind, unit|
          value = attributes[field]
          next unless value.is_a?(Numeric) && value.finite?

          metrics << { "name" => metric, "kind" => kind, "unit" => unit, "value" => [ value, 0 ].max, "labels" => labels }
        end
        Serialization.readonly_copy(
          "schemaVersion" => 1,
          "name" => event_name,
          "occurredAt" => Time.now.utc.iso8601(3),
          "adapter" => adapter,
          "actorType" => attributes["actorType"]&.to_s,
          "actorId" => attributes["actorId"]&.to_s,
          "incarnation" => (attributes["incarnation"] || attributes["instanceId"])&.to_s,
          "revision" => attributes["revision"]&.to_s,
          "messageId" => attributes["messageId"]&.to_s,
          "attempt" => attributes.fetch("attempt", 0),
          "attributes" => attributes,
          "metrics" => metrics
        )
      end

      # @rbs (Hash[Symbol, Object]) -> Hash[String, telemetry_value]
      def safe_attributes(payload)
        payload.each_with_object({}) do |(key, value), attributes|
          value = value.to_s if key == :reason && value.is_a?(Symbol)
          if %i[previous_interval current_interval].include?(key) && value.is_a?(Numeric)
            attributes["#{key.to_s.camelize(:lower)}Milliseconds"] = (value * 1000).round
            next
          end
          name = key.to_s.camelize(:lower)
          name = ALIASES.fetch(name, name)
          next unless FIELDS.include?(name)
          next unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

          value = value.camelize(:lower) if name == "waitingOn" && value.is_a?(String)
          value = value.to_s if !value.nil? && (name.end_with?("Id") || %w[revision sequence generation activationGeneration].include?(name))
          attributes[name] = value
        end
      end

      private

      # @rbs (Effect | Broadcast) -> Hash[Symbol, String | Integer]
      def outbox_identity(record)
        return { effect_id: record.effect_id, effect_name: record.name } if record.is_a?(Effect)

        { broadcast_id: record.broadcast_id, revision: record.message.sequence }
      end

      # @rbs (String, Exception) -> void
      def log_delivery_failure(event_name, error)
        SolidObjects.configuration.logger.error(
          {
            event: "solid_objects.instrumentation.failed",
            instrumentation_event: event_name,
            error_class: error.class.name
          }
        )
      rescue
        nil
      end
    end
  end
end
