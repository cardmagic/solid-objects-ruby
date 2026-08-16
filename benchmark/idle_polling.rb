# frozen_string_literal: true

require "json"
require "rbconfig"
require_relative "support"

class CountingWakeUp < SolidObjects::WakeUp
  def initialize
    super
    @count_mutex = Mutex.new
    @poll_count = 0
  end

  def wait(timeout:, generation: nil)
    @count_mutex.synchronize { @poll_count += 1 }
    super
  end

  def reset_count
    @count_mutex.synchronize { @poll_count = 0 }
  end

  def poll_count
    @count_mutex.synchronize { @poll_count }
  end
end

def measure(interval:, warmup:, duration:, wake_up:)
  SolidObjects.configuration.polling_interval = interval
  SolidObjects.configuration.idle_polling_interval = 1.0
  components = [
    SolidObjects::Worker.new,
    SolidObjects::EffectExecutor.new,
    SolidObjects::ReminderScheduler.new,
    SolidObjects::BroadcastExecutor.new
  ]
  threads = components.map { |component| Thread.new { component.run } }

  sleep warmup
  wake_up.reset_count
  cpu_started_at = Process.times
  wall_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  sleep duration
  wall_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_started_at
  cpu_finished_at = Process.times
  cpu_elapsed = cpu_finished_at.utime + cpu_finished_at.stime -
    cpu_started_at.utime - cpu_started_at.stime
  poll_count = wake_up.poll_count

  {
    polling_interval: interval,
    idle_polling_interval: SolidObjects.configuration.idle_polling_interval,
    current_intervals: components.map(&:current_polling_interval),
    polls: poll_count,
    polls_per_second: (poll_count / wall_elapsed).round(3),
    idle_cpu_percent: ((cpu_elapsed / wall_elapsed) * 100).round(3)
  }
ensure
  components&.each(&:request_shutdown)
  threads&.each { |thread| thread.join(2) }
  components&.each(&:stop)
end

intervals = ENV.fetch("INTERVALS", "0.02,0.1,0.5").split(",").map do |value|
  Float(value).tap { |interval| raise ArgumentError, "intervals must be positive" unless interval.positive? }
end
warmup = Float(ENV.fetch("WARMUP", "3"))
duration = Float(ENV.fetch("DURATION", "10"))
raise ArgumentError, "warmup must be positive" unless warmup.positive?
raise ArgumentError, "duration must be positive" unless duration.positive?

SolidObjectsBenchmark.setup
wake_up = CountingWakeUp.new
SolidObjects.configuration.wake_up_adapter = wake_up
database_version = ActiveRecord::Base.connection.select_value("SELECT sqlite_version()")
results = intervals.map { |interval| measure(interval:, warmup:, duration:, wake_up:) }
puts JSON.pretty_generate(
  measured_at: Time.now.utc.iso8601,
  package_version: SolidObjects::VERSION,
  runtime: {
    ruby: RUBY_DESCRIPTION,
    platform: RUBY_PLATFORM,
    cpu: RbConfig::CONFIG.fetch("host_cpu")
  },
  database: {
    adapter: "sqlite",
    version: database_version,
    path: SolidObjectsBenchmark::DATABASE_PATH
  },
  methodology: {
    roles: %w[actors effects reminders broadcasts],
    warmup_seconds: warmup,
    duration_seconds: duration,
    cpu_percent: "process user plus system CPU time divided by wall time"
  },
  results:
)
SolidObjectsBenchmark.teardown
