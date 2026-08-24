# rbs_inline: enabled

require "json"

# The external system in the at-least-once demo: a JSON file that records
# every delivery it accepts. With deduplication :off it accepts everything,
# which makes an at-least-once duplicate visible. With deduplication :on it
# accepts each stable effect id once, which is the documented remedy.
module AtLeastOnceSink
  # @rbs (String path) -> Array[Hash[String, untyped]]
  def self.read(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    []
  end

  # @rbs (path: String, effect_id: String, attempt: Integer, deduplication: Symbol) -> bool
  def self.record(path:, effect_id:, attempt:, deduplication:)
    deliveries = read(path)
    seen = deliveries.any? { |delivery| delivery.fetch("effect_id") == effect_id }
    return false if deduplication == :on && seen

    deliveries << { "effect_id" => effect_id, "attempt" => attempt }
    File.write(path, JSON.pretty_generate(deliveries))
    true
  end
end
