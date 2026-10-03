# frozen_string_literal: true

module PortableTelemetryAssertions
  TELEMETRY_CONTRACT = JSON.parse(File.read(File.expand_path("../compatibility/telemetry-events.json", __dir__))).freeze

  def assert_portable_attributes(event)
    name = event.fetch("name").delete_prefix("solid_objects.")
    attributes = event.fetch("attributes")
    contract = TELEMETRY_CONTRACT.fetch("events").find do |entry|
      entry.fetch("name") == name && entry.fetch("match", {}).all? { |key, value| attributes[key] == value }
    end

    assert contract, "#{name} has no portable attribute contract"
    assert_equal contract.fetch("attributes").sort, attributes.keys.sort, "#{name} attributes"
  end

  def assert_portable_events(events, names)
    names.each do |name|
      matching = events.select { |event| event.fetch("name") == "solid_objects.#{name}" }

      refute_empty matching, "expected a solid_objects.#{name} event"
      matching.each { |event| assert_portable_attributes(event) }
    end
  end
end
