# rbs_inline: enabled

module SolidObjects
  class ActorDefinition
    Handler = Data.define(:name, :block)
    StateMigration = Data.define(:from, :to, :block)

    # @rbs @state_definition: StateDefinition
    # @rbs @messages: Hash[Symbol, Handler]
    # @rbs @queries: Hash[Symbol, Handler]
    # @rbs @observables: Hash[Symbol, Handler]
    # @rbs @state_version: Integer
    # @rbs @state_migrations: Array[StateMigration]
    # @rbs @activation_hooks: Array[Proc]
    # @rbs @deactivation_hooks: Array[Proc]

    attr_reader :state_definition,
      :messages,
      :queries,
      :observables,
      :state_version,
      :state_migrations,
      :activation_hooks,
      :deactivation_hooks

    # @rbs () -> void
    def initialize
      @state_definition = StateDefinition.new
      @messages = {}
      @queries = {}
      @observables = {}
      @state_version = 1
      @state_migrations = []
      @activation_hooks = []
      @deactivation_hooks = []
    end

    # @rbs (Symbol | String, Proc) -> Handler
    def add_message(name, block)
      add_handler(messages, name, block)
    end

    # @rbs (Symbol | String, Proc) -> Handler
    def add_query(name, block)
      add_handler(queries, name, block)
    end

    # @rbs (Symbol | String, Proc?) -> Handler
    def add_observable(name, block = nil)
      observable_name = name.to_sym
      raise InvalidActor, "#{observable_name.inspect} observable is already defined" if observables.key?(observable_name)

      observable_block = block || -> { state.fetch(observable_name) }
      Handler.new(name: observable_name, block: observable_block).tap do |handler|
        observables[observable_name] = handler
      end
    end

    # @rbs (Integer) -> Integer
    def set_state_version(version)
      raise InvalidActor, "state version must be positive" unless version.positive?

      @state_version = version
    end

    # @rbs (Integer, Integer, Proc) -> StateMigration
    def add_state_migration(from, to, block)
      unless to == from + 1
        raise InvalidActor, "state migrations must advance exactly one version"
      end

      if state_migrations.any? { |migration| migration.from == from }
        raise InvalidActor, "state migration from version #{from} is already defined"
      end

      StateMigration.new(from:, to:, block:).tap { |migration| state_migrations << migration }
    end

    # @rbs (Integer, Hash[String, untyped]) -> Hash[String, untyped]
    def migrate_state(version, data)
      migrated = Serialization.deep_copy(data)
      current_version = version

      while current_version < state_version
        migration = state_migrations.find { |candidate| candidate.from == current_version }
        raise StateMigrationError, "missing state migration from version #{current_version}" unless migration

        migrated = Serialization.dump(migration.block.call(migrated))
        current_version = migration.to
      end

      if current_version > state_version
        raise StateMigrationError, "stored state version #{current_version} is newer than code version #{state_version}"
      end

      migrated
    rescue StateMigrationError
      raise
    rescue => error
      raise StateMigrationError, "state migration failed: #{error.message}"
    end

    # @rbs () -> ActorDefinition
    def duplicate
      self.class.new.tap do |copy|
        copy.instance_variable_set(:@state_definition, state_definition.duplicate)
        copy.instance_variable_set(:@messages, messages.dup)
        copy.instance_variable_set(:@queries, queries.dup)
        copy.instance_variable_set(:@observables, observables.dup)
        copy.instance_variable_set(:@state_version, state_version)
        copy.instance_variable_set(:@state_migrations, state_migrations.dup)
        copy.instance_variable_set(:@activation_hooks, activation_hooks.dup)
        copy.instance_variable_set(:@deactivation_hooks, deactivation_hooks.dup)
      end
    end

    private

    # @rbs (Hash[Symbol, Handler], Symbol | String, Proc) -> Handler
    def add_handler(collection, name, block)
      handler_name = name.to_sym
      raise InvalidActor, "#{handler_name.inspect} is already defined" if messages.key?(handler_name) || queries.key?(handler_name)

      Handler.new(name: handler_name, block:).tap { |handler| collection[handler_name] = handler }
    end
  end
end
