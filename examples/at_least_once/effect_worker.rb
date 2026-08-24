# rbs_inline: enabled

require_relative "boot"
require_relative "actor"
require_relative "sink"

database_path, sink_path, mode, deduplication = ARGV
raise ArgumentError, "usage: effect_worker.rb DATABASE SINK crash|complete on|off" unless deduplication

AtLeastOnceBoot.call(database_path.to_s)

SolidObjects.register_effect(:record) do |_arguments, context|
  AtLeastOnceSink.record(
    path: sink_path.to_s,
    effect_id: context.id,
    attempt: context.attempt,
    deduplication: deduplication.to_sym
  )
  # A crash between the external write and the acknowledgement: the sink
  # has the delivery, the effect row never completes.
  Process.exit!(1) if mode == "crash"
  nil
end

# Production runs this on the dead-process-cleanup interval; the demo runs
# it once, after the liveness threshold, to release the crashed claim.
SolidObjects::ProcessRegistry.cleanup_dead

effect_executor = SolidObjects::EffectExecutor.new
begin
  worked = false
  200.times do
    worked = effect_executor.run_once
    break if worked
    sleep 0.01
  end
  raise "no effect became claimable" unless worked
ensure
  effect_executor.stop
end
