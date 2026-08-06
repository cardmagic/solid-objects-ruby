# rbs_inline: enabled

require "active_record"
require "benchmark"
require "fileutils"
require "solid_objects"

module SolidObjectsBenchmark
  DATABASE_PATH = File.expand_path("../tmp/solid_objects_benchmark.sqlite3", __dir__)

  class CounterActor < SolidObjects::Actor
    actor_type "benchmark-counter"

    attribute :count, default: 0

    message :increment do
      state.count += 1
    end

    query :count do
      state.count
    end
  end

  class << self
    # @rbs () -> Integer
    def count
      Integer(ENV.fetch("COUNT", "500"))
    end

    # @rbs () -> Integer
    def concurrency
      Integer(ENV.fetch("CONCURRENCY", "4"))
    end

    # @rbs () -> void
    def setup
      establish_connection
      migrate
      load_models
      SolidObjects.configuration.logger = Logger.new(nil)
      SolidObjects.configuration.authorize_message = ->(**) { true }
      SolidObjects.configuration.authorize_query = ->(**) { true }
    end

    # @rbs () -> void
    def teardown
      ActiveRecord::Base.connection_pool.disconnect!
      FileUtils.rm_f(DATABASE_PATH) unless ENV["SOLID_OBJECTS_DATABASE_URL"]
    end

    # @rbs (String) { () -> untyped } -> Float
    def measure(name)
      elapsed = Benchmark.realtime { yield }
      throughput = count / elapsed
      puts "#{name}: #{format("%.3f", elapsed)}s, #{format("%.1f", throughput)} operations/s"
      elapsed
    end

    # @rbs () -> void
    def enqueue
      reference = CounterActor.ref("enqueue")
      measure("enqueue #{count} messages") do
        count.times { reference.async(:increment) }
      end
    end

    # @rbs () -> void
    def claim
      count.times { |index| CounterActor.ref("claim-#{index}").async(:increment) }
      process_registry = SolidObjects::ProcessRegistry.new
      owner_id = process_registry.register.id
      activation_manager = SolidObjects::ActivationManager.new(owner_id:)
      claimed_instance_ids = {}

      measure("claim #{count} actors") do
        count.times do
          activation = activation_manager.claim_next
          raise "actor was not claimable" unless activation
          instance_id = activation.lease.instance_id
          raise "actor was claimed twice" if claimed_instance_ids[instance_id]

          claimed_instance_ids[instance_id] = true
          SolidObjects::ReadyMessage.where(instance_id:).delete_all
          activation.deactivate
        end
      end
    ensure
      process_registry&.stop
    end

    # @rbs () -> void
    def processing
      enqueue_round_robin
      worker = SolidObjects::Worker.new
      measure("process #{count} messages") { drain(worker) }
    ensure
      worker&.stop
    end

    # @rbs () -> void
    def cold_actors
      count.times { |index| CounterActor.ref("cold-#{index}").async(:increment) }
      worker = SolidObjects::Worker.new
      measure("process #{count} cold actors") { drain(worker) }
    ensure
      worker&.stop
    end

    # @rbs () -> void
    def hot_actor
      reference = CounterActor.ref("hot")
      count.times { reference.async(:increment) }
      worker = SolidObjects::Worker.new
      measure("process #{count} messages for one hot actor") { drain(worker) }
    ensure
      worker&.stop
    end

    # @rbs () -> void
    def concurrent_actors
      enqueue_round_robin
      workers = Array.new(concurrency) { SolidObjects::Worker.new }
      measure("process #{count} messages with #{concurrency} workers") do
        threads = workers.map { |worker| Thread.new { drain(worker) } }
        threads.each(&:join)
      end
    ensure
      workers&.each(&:stop)
    end

    # @rbs () -> void
    def sync_latency
      samples = []

      count.times do |index|
        started_at = monotonic_now
        CounterActor.ref("sync-#{index}").sync(:count, timeout: 5)
        samples << monotonic_now - started_at
      end

      sorted = samples.sort
      puts "sync #{count} calls: p50=#{milliseconds(percentile(sorted, 0.50))}ms " \
        "p95=#{milliseconds(percentile(sorted, 0.95))}ms " \
        "p99=#{milliseconds(percentile(sorted, 0.99))}ms"
    end

    # @rbs () -> void
    def adoption_latency
      instance_count = SolidObjects::Instance.count
      message_count = SolidObjects::Message.count

      cold_elapsed = Benchmark.realtime do
        CounterActor.ref("adoption-cold").increment
      end

      reference = CounterActor.ref("adoption-warm")
      reference.increment
      write_samples = Array.new(count) do
        Benchmark.realtime { reference.increment }
      end
      read_samples = Array.new(count) do
        Benchmark.realtime { reference.count }
      end

      puts "first cold call: #{milliseconds(cold_elapsed)}ms"
      puts latency_summary("warm writes", write_samples)
      puts latency_summary("ordered reads", read_samples)
      puts "durable row growth: " \
        "instances=+#{SolidObjects::Instance.count - instance_count}, " \
        "messages=+#{SolidObjects::Message.count - message_count}"
    end

    # @rbs () -> void
    def activation_cache
      reference = CounterActor.ref("cache")
      count.times { reference.async(:increment) }
      activations = 0
      subscriber = ActiveSupport::Notifications.subscribe("solid_objects.activation.started") do
        activations += 1
      end
      worker = SolidObjects::Worker.new
      processed = drain(worker)
      hit_rate = processed.zero? ? 0.0 : 1.0 - (activations.to_f / processed)
      puts "activation cache: #{processed} messages, #{activations} activations, " \
        "#{format("%.1f", hit_rate * 100)}% reuse"
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      worker&.stop
    end

    # @rbs () -> void
    def query_count
      CounterActor.ref("queries").async(:increment)
      worker = SolidObjects::Worker.new
      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        next if %w[SCHEMA TRANSACTION].include?(event.payload[:name])
        next if event.payload[:cached]

        queries += 1
      end
      processed = worker.run_once
      puts "database queries: #{queries} for #{processed} message"
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      worker&.stop
    end

    private

    # @rbs () -> void
    def establish_connection
      database_url = ENV["SOLID_OBJECTS_DATABASE_URL"]
      FileUtils.mkdir_p(File.dirname(DATABASE_PATH))
      FileUtils.rm_f(DATABASE_PATH) unless database_url
      ActiveRecord::Base.establish_connection(
        database_url || {
          adapter: "sqlite3",
          database: DATABASE_PATH,
          pool: concurrency + 5,
          timeout: 5_000
        }
      )
      ActiveRecord::Migration.verbose = false
    end

    # @rbs () -> void
    def migrate
      require_relative "../db/migrate/20260805000000_create_solid_objects_tables"
      CreateSolidObjectsTables.new.migrate(:up)
    end

    # @rbs () -> void
    def load_models
      %w[
        record
        process
        instance
        message
        ready_message
        claimed_message
        reminder
        effect
        broadcast
        dead_letter
      ].each do |model|
        require_relative "../app/models/solid_objects/#{model}"
      end
    end

    # @rbs () -> void
    def enqueue_round_robin
      actor_count = [ concurrency * 10, count ].min
      references = Array.new(actor_count) { |index| CounterActor.ref("actor-#{index}") }
      count.times { |index| references[index % actor_count].async(:increment) }
    end

    # @rbs (SolidObjects::Worker) -> Integer
    def drain(worker)
      processed = 0
      idle_passes = 0

      while SolidObjects::ReadyMessage.exists? || SolidObjects::ClaimedMessage.exists?
        pass_count = worker.run_once
        processed += pass_count
        idle_passes = pass_count.zero? ? idle_passes + 1 : 0
        raise "benchmark made no progress" if idle_passes >= 1_000
      end

      processed
    end

    # @rbs () -> Float
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # @rbs (Array[Float], Float) -> Float
    def percentile(samples, fraction)
      samples.fetch(((samples.length - 1) * fraction).ceil)
    end

    # @rbs (String, Array[Float]) -> String
    def latency_summary(name, samples)
      sorted = samples.sort
      "#{name} #{samples.length} calls: " \
        "median=#{milliseconds(percentile(sorted, 0.50))}ms " \
        "min=#{milliseconds(sorted.first)}ms " \
        "max=#{milliseconds(sorted.last)}ms"
    end

    # @rbs (Float) -> String
    def milliseconds(seconds)
      format("%.1f", seconds * 1_000)
    end
  end
end

SolidObjectsBenchmark.setup
at_exit { SolidObjectsBenchmark.teardown }
