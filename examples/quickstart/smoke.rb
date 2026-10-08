# rbs_inline: enabled

require "bundler"
require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "rubygems/package"
require "timeout"
require "tmpdir"

class QuickstartSmoke
  class Failure < StandardError; end

  HoldProcess = Data.define(:buyer, :pid, :input, :output)

  REPOSITORY_ROOT = File.expand_path("../..", __dir__)
  QUICKSTART_ROOT = __dir__
  ACTOR_PATH = File.join(QUICKSTART_ROOT, "app/actors/ticket_sale.rb")
  RECIPE_PATH = File.join(QUICKSTART_ROOT, "README.md")
  INITIALIZER = "config/initializers/solid_objects.rb"
  DEMO_GRANTS = {
    "configuration.authorize_message = ->(**) { false }" => "configuration.authorize_message = ->(**) { true }",
    "configuration.authorize_query = ->(**) { false }" => "configuration.authorize_query = ->(**) { true }"
  }.freeze
  DENIED_POLICIES = %w[authorize_destroy authorize_subscription authorize_administration authorize_transmission].freeze
  CONCURRENT_BUYERS = 8
  RESTART_DEADLINE_SECONDS = 8
  COMMAND_TIMEOUT_SECONDS = 600
  RECOVERY_TIMEOUT_SECONDS = 60

  HOLD_PROGRAM = <<~RUBY
    $stdout.sync = true
    puts "ready"
    $stdin.gets
    puts JSON.generate(TicketSale.ref(ARGV.fetch(0)).hold(buyer: ARGV.fetch(1)))
  RUBY

  SHIFTED_CLOCK_HOLD_PROGRAM = <<~RUBY
    require "active_support/testing/time_helpers"
    include ActiveSupport::Testing::TimeHelpers
    travel_to(Time.current - 10.minutes + Integer(ARGV.fetch(2)).seconds) do
      puts JSON.generate(TicketSale.ref(ARGV.fetch(0)).hold(buyer: ARGV.fetch(1)))
    end
  RUBY

  STATE_PROGRAM = <<~RUBY
    puts JSON.generate(TicketSale.ref(ARGV.fetch(0)).snapshot.to_h)
  RUBY

  RECOVERY_PROGRAM = <<~RUBY
    sale = TicketSale.ref(ARGV.fetch(0))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Integer(ARGV.fetch(1))
    state = sale.snapshot.to_h
    until state.fetch("holds").empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.25
      state = sale.snapshot.to_h
    end
    puts JSON.generate(state)
  RUBY

  RESOLUTION_PROGRAM = <<~RUBY
    specification = Gem.loaded_specs.fetch("solid_objects")
    puts JSON.generate(
      version: SolidObjects::VERSION,
      rails: Rails.version,
      json: JSON::VERSION,
      full_gem_path: specification.full_gem_path,
      cache_file: specification.cache_file,
      loaded_feature: $LOADED_FEATURES.find { |feature| feature.end_with?("/solid_objects/version.rb") }
    )
  RUBY

  # @rbs @root: String
  # @rbs @log_directory: String
  # @rbs @application_path: String
  # @rbs @bundle_path: String
  # @rbs @child_pids: Array[Integer]
  # @rbs @started_at: Float

  # @rbs () -> void
  def initialize
    @root = Dir.mktmpdir("solid_objects_quickstart_")
    @log_directory = File.join(@root, "logs")
    @application_path = File.join(@root, "ticket_demo")
    @bundle_path = File.join(@root, "bundle")
    @child_pids = []
    @started_at = monotonic_now
  end

  # @rbs () -> void
  def call
    actor_source = verify_recipe
    artifact = build_gem
    generate_application
    install_bundle(artifact)
    resolution = verify_resolution(artifact)
    install_solid_objects(actor_source)
    concurrency = prove_concurrent_holds
    restart = prove_restart_recovery
    puts JSON.pretty_generate(
      artifact: { version: artifact.fetch(:version), sha256: artifact.fetch(:sha256), resolved_from: resolution.fetch("full_gem_path") },
      application: { rails: resolution.fetch("rails"), json: resolution.fetch("json") },
      concurrency:,
      restart:,
      seconds: (monotonic_now - @started_at).round(1)
    )
  ensure
    stop_children
    FileUtils.remove_entry(@root) if File.exist?(@root)
  end

  private

  # @rbs () -> String
  def verify_recipe
    prove("examples/quickstart/README.md exists") { File.file?(RECIPE_PATH) }
    prove("examples/quickstart/app/actors/ticket_sale.rb exists") { File.file?(ACTOR_PATH) }
    actor_source = File.read(ACTOR_PATH).delete_prefix("# rbs_inline: enabled\n\n")
    recipe = File.read(RECIPE_PATH)
    prove("the recipe shows the exact actor that the check runs") { recipe.include?(actor_source) }
    DEMO_GRANTS.each_value do |grant|
      prove("the recipe shows the demo grant #{grant}") { recipe.include?(grant) }
    end
    published_samples.each do |path, sample|
      prove("#{path} shows the same TicketSale actor") { sample == actor_source.strip }
    end
    actor_source
  end

  # @rbs () -> Array[[String, String]]
  def published_samples
    paths = Dir[File.join(REPOSITORY_ROOT, "{README.md,docs/**/*.md,examples/**/*.md}")]
    paths.flat_map do |path|
      relative_path = path.delete_prefix("#{REPOSITORY_ROOT}/")
      File.read(path).scan(/```ruby\n(class TicketSale < SolidObjects::Actor\n.*?\nend)\n```/m).map do |(sample)|
        [ relative_path, sample ]
      end
    end
  end

  # @rbs () -> Hash[Symbol, String]
  def build_gem
    artifact_directory = File.join(@root, "artifact")
    FileUtils.mkdir_p(artifact_directory)
    version = File.read(File.join(REPOSITORY_ROOT, "lib/solid_objects/version.rb"))[/VERSION = "([^"]+)"/, 1] ||
      raise(Failure, "lib/solid_objects/version.rb declares no version")
    path = File.join(artifact_directory, "solid_objects-#{version}.gem")
    run_in_repository("gem-build", RbConfig.ruby, gem_executable, "build", "solid_objects.gemspec", "--output", path)
    prove("the built gem declares version #{version}") { Gem::Package.new(path).spec.version.to_s == version }
    { path:, version:, sha256: Digest::SHA256.file(path).hexdigest }
  end

  # @rbs () -> void
  def generate_application
    run_in_repository(
      "rails-new",
      RbConfig.ruby, Gem.bin_path("railties", "rails"), "new", @application_path,
      "--minimal", "--skip-bundle", "--skip-git", "--skip-test", "--skip-system-test", "--quiet"
    )
  end

  # @rbs (Hash[Symbol, String]) -> void
  def install_bundle(artifact)
    gemfile = File.join(@application_path, "Gemfile")
    run_in_application("bundle-install", RbConfig.ruby, bundle_executable, "install")
    cache_directory = File.join(@application_path, "vendor/cache")
    FileUtils.mkdir_p(cache_directory)
    FileUtils.cp(artifact.fetch(:path), cache_directory)
    File.write(gemfile, "#{File.read(gemfile)}\ngem \"solid_objects\", \"= #{artifact.fetch(:version)}\"\n")
    run_in_application("bundle-install-local", RbConfig.ruby, bundle_executable, "install", "--local")
  end

  # @rbs (Hash[Symbol, String]) -> Hash[String, String]
  def verify_resolution(artifact)
    gemfile = File.read(File.join(@application_path, "Gemfile"))
    prove("the Gemfile names no path dependency") { !gemfile.match?(/^\s*gem\s+"solid_objects".*path:/) }
    lockfile = File.read(File.join(@application_path, "Gemfile.lock"))
    prove("Gemfile.lock records the checksum of the built gem") do
      lockfile.include?("solid_objects (#{artifact.fetch(:version)}) sha256=#{artifact.fetch(:sha256)}")
    end
    resolution = JSON.parse(rails_runner("resolution", RESOLUTION_PROGRAM).lines.last)
    prove("the application loads the built version") { resolution.fetch("version") == artifact.fetch(:version) }
    prove("the gem resolves inside the isolated bundle") { resolution.fetch("full_gem_path").start_with?(@bundle_path) }
    loaded_feature = resolution.fetch("loaded_feature").to_s
    prove("the gem loads its files from the isolated bundle") { loaded_feature.start_with?(@bundle_path) }
    prove("the gem does not resolve to the repository") { !loaded_feature.start_with?(REPOSITORY_ROOT) }
    prove("the installed gem is the built artifact") do
      Digest::SHA256.file(resolution.fetch("cache_file")).hexdigest == artifact.fetch(:sha256)
    end
    resolution
  end

  # @rbs (String) -> void
  def install_solid_objects(actor_source)
    run_in_application("generate", RbConfig.ruby, "bin/rails", "generate", "solid_objects:install")
    run_in_application("migrate", RbConfig.ruby, "bin/rails", "db:migrate")
    doctor = run_in_application("doctor", RbConfig.ruby, "bin/rails", "solid_objects:doctor")
    prove("the doctor warns that every policy denies by default") { doctor.include?("all five policies denied") }
    actor_path = File.join(@application_path, "app/actors/ticket_sale.rb")
    FileUtils.mkdir_p(File.dirname(actor_path))
    File.write(actor_path, actor_source)
    grant_demo_policies
  end

  # @rbs () -> void
  def grant_demo_policies
    path = File.join(@application_path, INITIALIZER)
    initializer = File.read(path)
    DEMO_GRANTS.each do |denial, grant|
      prove("the generated initializer denies with #{denial}") { initializer.include?(denial) }
      initializer = initializer.sub(denial, grant)
    end
    DENIED_POLICIES.each do |policy|
      prove("#{policy} stays denied") { initializer.include?("configuration.#{policy} = ->(**) { false }") }
    end
    File.write(path, initializer)
  end

  # @rbs () -> Hash[Symbol, Integer]
  def prove_concurrent_holds
    runtime = start_runtime("runtime-concurrency")
    buyers = (1..CONCURRENT_BUYERS).map { |number| "buyer-#{number}" }
    holders = buyers.map { |buyer| spawn_hold(event: "concert", buyer:) }
    holders.each { |holder| await_ready(holder) }
    holders.each do |holder|
      holder.input.puts("go")
      holder.input.close
    end
    results = holders.to_h { |holder| [ holder.buyer, read_hold(holder) ] }
    prove("the runtime kept running during the concurrent holds") { alive?(runtime) }
    stop_runtime(runtime)
    winners = results.select { |_, result| result.fetch("held") }.keys
    state = read_state("concert")
    prove("exactly one concurrent buyer held the only ticket") { winners.length == 1 }
    prove("no concurrent update was lost") do
      state.fetch("available").zero? && state.fetch("holds").keys == winners
    end
    { calls: buyers.length, held: winners.length, available: state.fetch("available") }
  end

  # @rbs () -> Hash[Symbol, Integer]
  def prove_restart_recovery
    hold = JSON.parse(
      rails_runner("shifted-hold", SHIFTED_CLOCK_HOLD_PROGRAM, "matinee", "ada", RESTART_DEADLINE_SECONDS.to_s).lines.last
    )
    due_at = Time.now + RESTART_DEADLINE_SECONDS
    prove("the restart hold succeeded while the runtime was stopped") { hold.fetch("held") }
    sleep [ due_at + 2 - Time.now, 0 ].max
    stopped = read_state("matinee")
    prove("the due reminder waited while no runtime ran") do
      stopped.fetch("available").zero? && stopped.fetch("holds").key?("ada")
    end
    runtime = start_runtime("runtime-recovery")
    recovered = JSON.parse(
      rails_runner("recovery", RECOVERY_PROGRAM, "matinee", RECOVERY_TIMEOUT_SECONDS.to_s).lines.last
    )
    stop_runtime(runtime)
    prove("the reminder ran after the restart and released the hold once") do
      recovered.fetch("available") == 1 && recovered.fetch("holds").empty?
    end
    { available_while_stopped: stopped.fetch("available"), available_after_restart: recovered.fetch("available") }
  end

  # @rbs (event: String, buyer: String) -> HoldProcess
  def spawn_hold(event:, buyer:)
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    pid = spawn_in_application(
      "hold-#{buyer}", RbConfig.ruby, "bin/rails", "runner", HOLD_PROGRAM, event, buyer,
      in: input_reader, out: output_writer
    )
    input_reader.close
    output_writer.close
    HoldProcess.new(buyer:, pid:, input: input_writer, output: output_reader)
  end

  # @rbs (HoldProcess) -> void
  def await_ready(holder)
    Timeout.timeout(COMMAND_TIMEOUT_SECONDS) do
      line = holder.output.gets
      raise Failure, "#{holder.buyer} exited before it was ready\n#{log_tail("hold-#{holder.buyer}")}" if line.nil?
      raise Failure, "#{holder.buyer} printed #{line.inspect} before it was ready" unless line == "ready\n"
    end
  end

  # @rbs (HoldProcess) -> Hash[String, untyped]
  def read_hold(holder)
    output = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) { holder.output.read }
    holder.output.close
    status = wait(holder.pid)
    raise Failure, "#{holder.buyer} failed\n#{log_tail("hold-#{holder.buyer}")}" unless status.success?
    JSON.parse(output.lines.last)
  end

  # @rbs (String) -> Hash[String, untyped]
  def read_state(event)
    JSON.parse(rails_runner("state-#{event}", STATE_PROGRAM, event).lines.last)
  end

  # @rbs (String) -> Integer
  def start_runtime(name)
    spawn_in_application(name, RbConfig.ruby, bundle_executable, "exec", "solid_objects", "start")
  end

  # @rbs (Integer) -> void
  def stop_runtime(pid)
    ::Process.kill("TERM", pid)
    status = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) { wait(pid) }
    raise Failure, "the runtime did not stop cleanly: #{status.inspect}" unless status.success?
  end

  # @rbs (String, String, *String) -> String
  def rails_runner(name, program, *arguments)
    run_in_application(name, RbConfig.ruby, "bin/rails", "runner", program, *arguments)
  end

  # @rbs (String, *String) -> String
  def run_in_repository(name, *command)
    pid = spawn_logged(name, command, environment: {}, chdir: REPOSITORY_ROOT)
    finish(name, pid)
  end

  # @rbs (String, *String) -> String
  def run_in_application(name, *command)
    pid = Bundler.with_unbundled_env do
      spawn_logged(name, command, environment: application_environment, chdir: @application_path)
    end
    finish(name, pid)
  end

  # @rbs (String, *untyped, **untyped) -> Integer
  def spawn_in_application(name, *command, **options)
    Bundler.with_unbundled_env do
      spawn_logged(name, command, environment: application_environment, chdir: @application_path, **options)
    end
  end

  # @rbs (String, Array[String], environment: Hash[String, String], chdir: String, **untyped) -> Integer
  def spawn_logged(name, command, environment:, chdir:, **options)
    FileUtils.mkdir_p(@log_directory)
    log_path = File.join(@log_directory, "#{name}.log")
    pid = ::Process.spawn(environment, *command, { chdir:, out: log_path, err: log_path }.merge(options))
    @child_pids << pid
    pid
  end

  # @rbs (String, Integer) -> String
  def finish(name, pid)
    status = Timeout.timeout(COMMAND_TIMEOUT_SECONDS) { wait(pid) }
    raise Failure, "#{name} failed with #{status.inspect}\n#{log_tail(name)}" unless status.success?
    File.read(File.join(@log_directory, "#{name}.log"))
  end

  # @rbs (Integer) -> Process::Status
  def wait(pid)
    _pid, status = ::Process.wait2(pid)
    @child_pids.delete(pid)
    status
  end

  # @rbs (Integer) -> bool
  def alive?(pid)
    ::Process.waitpid(pid, ::Process::WNOHANG).nil?
  end

  # @rbs () -> void
  def stop_children
    @child_pids.dup.each do |pid|
      ::Process.kill("TERM", pid)
      Timeout.timeout(20) { wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      @child_pids.delete(pid)
    rescue Timeout::Error
      ::Process.kill("KILL", pid)
      wait(pid)
    end
  end

  # @rbs () -> Hash[String, String]
  def application_environment
    {
      "BUNDLE_GEMFILE" => File.join(@application_path, "Gemfile"),
      "BUNDLE_PATH" => @bundle_path,
      "BUNDLE_DEPLOYMENT" => "false",
      "BUNDLE_FROZEN" => "false",
      "BUNDLE_JOBS" => "4",
      "RAILS_ENV" => "development"
    }
  end

  # @rbs (String) -> String
  def log_tail(name)
    path = File.join(@log_directory, "#{name}.log")
    return "(no log)" unless File.file?(path)

    File.readlines(path).last(40).join
  end

  # @rbs () -> String
  def gem_executable
    File.join(RbConfig::CONFIG.fetch("bindir"), "gem")
  end

  # @rbs () -> String
  def bundle_executable
    Gem.bin_path("bundler", "bundle")
  end

  # @rbs () -> Float
  def monotonic_now
    ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
  end

  # @rbs (String) { () -> boolish } -> void
  def prove(claim)
    raise Failure, "quickstart proof failed: #{claim}" unless yield
  end
end

QuickstartSmoke.new.call
