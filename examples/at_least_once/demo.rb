# rbs_inline: enabled

# An executable proof for the at-least-once clause: a contract clause
# nobody can observe firing is decoration. Run with:
#
#   bundle exec rake at_least_once
#
# Phase one crashes an effect worker between the external sink write and
# the acknowledgement, restarts one, and shows the sink reading 2 with
# deduplication off. Both deliveries carry the same stable effect id.
# Phase two repeats the crash with a guard on that id; the sink reads 1.
# The actor state commits exactly once in both phases.

require_relative "boot"
require_relative "actor"
require_relative "sink"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

directory = Dir.mktmpdir("solid_objects_at_least_once_")
database_path = File.join(directory, "state.sqlite3")
AtLeastOnceBoot.call(database_path)

# @rbs (String message) -> void
def prove(message)
  raise "proof failed: #{message}" unless yield
end

# @rbs (String actor_id) -> void
def stage_one_delivery(actor_id)
  DeliveryCounter.ref(actor_id).async.deliver
  worker = SolidObjects::Worker.new
  begin
    worker.run_until_idle
  ensure
    worker.stop
  end
end

# @rbs (database_path: String, sink_path: String, mode: String, deduplication: String) -> Integer?
def run_effect_worker(database_path:, sink_path:, mode:, deduplication:)
  script = File.expand_path("effect_worker.rb", __dir__)
  pid = Process.spawn(
    RbConfig.ruby, script, database_path, sink_path, mode, deduplication,
    chdir: AtLeastOnceBoot::ROOT
  )
  _pid, status = Process.wait2(pid)
  status.exitstatus
end

# @rbs (database_path: String, sink_path: String, deduplication: String) -> void
def crash_then_recover(database_path:, sink_path:, deduplication:)
  crash = run_effect_worker(database_path:, sink_path:, mode: "crash", deduplication:)
  prove("the first delivery crashed before acknowledgement") { crash == 1 }
  sleep 0.4
  recovery = run_effect_worker(database_path:, sink_path:, mode: "complete", deduplication:)
  prove("the second delivery completed and acknowledged") { recovery == 0 }
end

begin
  sink_off = File.join(directory, "sink-dedup-off.json")
  stage_one_delivery("dedup-off")
  crash_then_recover(database_path:, sink_path: sink_off, deduplication: "off")
  deliveries = AtLeastOnceSink.read(sink_off)
  effect_ids = deliveries.map { |delivery| delivery.fetch("effect_id") }
  state_off = SolidObjects::Instance.find_by!(actor_id: "dedup-off").state.fetch("count")
  prove("the state commit happened exactly once") { state_off == 1 }
  prove("the sink observed the duplicate") { deliveries.length == 2 }
  prove("both deliveries carried the same stable effect id") { effect_ids.uniq.length == 1 }

  sink_on = File.join(directory, "sink-dedup-on.json")
  stage_one_delivery("dedup-on")
  crash_then_recover(database_path:, sink_path: sink_on, deduplication: "on")
  guarded = AtLeastOnceSink.read(sink_on)
  state_on = SolidObjects::Instance.find_by!(actor_id: "dedup-on").state.fetch("count")
  prove("the state commit happened exactly once") { state_on == 1 }
  prove("the stable effect id absorbed the duplicate") { guarded.length == 1 }

  puts JSON.pretty_generate(
    duplicate: {
      state_commits: state_off,
      sink_deliveries: deliveries.length,
      same_effect_id: effect_ids.uniq.length == 1,
      attempts: deliveries.map { |delivery| delivery.fetch("attempt") }
    },
    remedy: { state_commits: state_on, sink_deliveries: guarded.length }
  )
ensure
  FileUtils.remove_entry(directory) if directory
end
