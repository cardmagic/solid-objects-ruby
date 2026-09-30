# rbs_inline: enabled

module SolidObjects
  module Telemetry
    FIELDS = %w[
      actorType actorId instanceId incarnation revision messageId requestId attempt sequence
      operation deliveryMode generation durationMilliseconds latenessMilliseconds ageMilliseconds
      depth count errorName outcome retryable status effectId effectName reminderId occurrence
      truncated broadcastId code role reason processId processKind ownerId componentCount byteCount
      thresholdBytes previousRunAt nextRunAt name commitAction payload
    ].freeze
    ALIASES = { "errorClass" => "errorName", "stateRevision" => "revision", "durationMs" => "durationMilliseconds" }.freeze

    class << self
      # @rbs (Symbol, Hash[Symbol, untyped]) -> void
      def emit(name, payload)
        observer = SolidObjects.configuration.instrumentation
        return unless observer

        observer.call(event(name, payload))
      rescue
        nil
      end

      # @rbs (Symbol, Hash[Symbol, untyped]) -> Hash[String, untyped]
      def event(name, payload)
        attributes = safe_attributes(payload)
        adapter = DatabaseAdapter.family(Record.connection).to_s
        event_name = "solid_objects.#{name}"
        labels = { "event" => event_name, "adapter" => adapter, "actorType" => attributes.fetch("actorType", "") }
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

      # @rbs (Hash[Symbol, untyped]) -> Hash[String, untyped]
      def safe_attributes(payload)
        payload.each_with_object({}) do |(key, value), attributes|
          name = key.to_s.camelize(:lower)
          name = ALIASES.fetch(name, name)
          next unless FIELDS.include?(name)
          next unless value.nil? || value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false

          value = value.to_s if !value.nil? && (name.end_with?("Id") || %w[revision sequence generation].include?(name))
          attributes[name] = value
        end
      end
    end
  end
end
