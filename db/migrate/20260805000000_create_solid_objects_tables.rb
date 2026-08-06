# rbs_inline: enabled

class CreateSolidObjectsTables < ActiveRecord::Migration[8.0]
  # @rbs () -> void
  def change
    create_processes
    create_instances
    create_messages
    create_message_memberships
    create_reminders
    create_effects
    create_broadcasts
    create_dead_letters
  end

  private

  # @rbs (Symbol) -> String
  def table(name)
    SolidObjects.table_name(name)
  end

  # @rbs () -> Symbol
  def json_column_type
    connection.adapter_name.match?(/postgres/i) ? :jsonb : :json
  end

  # @rbs (untyped, Symbol, ?null: bool) -> void
  def json_column(definition, name, null: true)
    definition.public_send(json_column_type, name, null:)
  end

  # @rbs () -> void
  def create_processes
    create_table table(:processes), id: :string, limit: 36 do |definition|
      definition.string :kind, null: false, limit: 64
      definition.string :hostname, null: false, limit: 255
      definition.bigint :pid, null: false
      definition.datetime :started_at, null: false, precision: 6
      definition.datetime :last_heartbeat_at, null: false, precision: 6
      json_column definition, :metadata, null: false
      definition.string :shutdown_state, null: false, default: "running", limit: 32
      definition.datetime :shutdown_requested_at, precision: 6
      definition.datetime :stopped_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index [ :shutdown_state, :last_heartbeat_at ], name: "idx_so_processes_liveness"
      definition.index [ :kind, :shutdown_state ], name: "idx_so_processes_kind"
      definition.check_constraint "shutdown_state IN ('running', 'draining', 'stopped')",
        name: "chk_so_process_shutdown"
    end
  end

  # @rbs () -> void
  def create_instances
    create_table table(:instances) do |definition|
      definition.string :actor_type, null: false, limit: 191
      definition.string :actor_id, null: false, limit: 191
      json_column definition, :state, null: false
      definition.integer :state_version, null: false, default: 1
      definition.bigint :next_message_sequence, null: false, default: 1
      definition.string :activation_owner_id, limit: 36
      definition.datetime :activation_expires_at, precision: 6
      definition.bigint :activation_generation, null: false, default: 0
      definition.datetime :activated_at, precision: 6
      definition.datetime :last_used_at, precision: 6
      definition.datetime :last_claimed_at, precision: 6
      definition.datetime :paused_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index [ :actor_type, :actor_id ], unique: true, name: "idx_so_instances_identity"
      definition.index [ :activation_expires_at, :last_claimed_at, :id ], name: "idx_so_instances_lease"
      definition.index :activation_owner_id, name: "idx_so_instances_owner"
      definition.index [ :last_used_at, :id ], name: "idx_so_instances_cleanup"
      definition.check_constraint "state_version > 0", name: "chk_so_instances_state_version"
      definition.check_constraint "next_message_sequence > 0", name: "chk_so_instances_sequence"
      definition.check_constraint "activation_generation >= 0", name: "chk_so_instances_generation"
    end

    add_foreign_key table(:instances),
      table(:processes),
      column: :activation_owner_id,
      on_delete: :nullify,
      name: "fk_so_instances_owner"
  end

  # @rbs () -> void
  def create_messages
    create_table table(:messages) do |definition|
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_messages_instance" }
      definition.string :actor_type, null: false, limit: 191
      definition.string :actor_id, null: false, limit: 191
      definition.string :message_name, null: false, limit: 191
      definition.string :message_kind, null: false, limit: 32
      json_column definition, :arguments, null: false
      definition.bigint :sequence, null: false
      definition.integer :attempt_count, null: false, default: 0
      definition.integer :max_attempts, null: false
      definition.string :request_id, null: false, limit: 36
      definition.string :idempotency_key, limit: 191
      json_column definition, :result
      json_column definition, :error
      definition.datetime :enqueued_at, null: false, precision: 6
      definition.datetime :available_at, null: false, precision: 6
      definition.datetime :started_at, precision: 6
      definition.datetime :completed_at, precision: 6
      definition.datetime :last_failed_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index [ :instance_id, :sequence ], unique: true, name: "idx_so_messages_instance_sequence"
      definition.index [ :actor_type, :actor_id, :sequence ], unique: true, name: "idx_so_messages_actor_sequence"
      definition.index :request_id, unique: true, name: "idx_so_messages_request"
      definition.index [ :instance_id, :idempotency_key ], unique: true, name: "idx_so_messages_idempotency"
      definition.index [ :completed_at, :id ], name: "idx_so_messages_cleanup"
      definition.check_constraint "sequence > 0", name: "chk_so_messages_sequence"
      definition.check_constraint "attempt_count >= 0", name: "chk_so_messages_attempt"
      definition.check_constraint "max_attempts > 0", name: "chk_so_messages_max_attempts"
      definition.check_constraint "message_kind IN ('tell', 'ask', 'internal')", name: "chk_so_messages_kind"
    end
  end

  # @rbs () -> void
  def create_message_memberships
    create_table table(:ready_messages) do |definition|
      definition.references :message,
        null: false,
        foreign_key: { to_table: table(:messages), on_delete: :cascade, name: "fk_so_ready_message" }
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_ready_instance" }
      definition.bigint :sequence, null: false
      definition.datetime :available_at, null: false, precision: 6
      definition.datetime :created_at, null: false, precision: 6

      definition.index :message_id, unique: true, name: "idx_so_ready_message"
      definition.index [ :instance_id, :sequence ], unique: true, name: "idx_so_ready_instance_sequence"
      definition.index [ :available_at, :instance_id, :sequence ], name: "idx_so_ready_poll"
      definition.check_constraint "sequence > 0", name: "chk_so_ready_sequence"
    end

    create_table table(:claimed_messages) do |definition|
      definition.references :message,
        null: false,
        foreign_key: { to_table: table(:messages), on_delete: :cascade, name: "fk_so_claimed_message" }
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_claimed_instance" }
      definition.string :process_id, limit: 36
      definition.bigint :activation_generation, null: false
      definition.datetime :claimed_at, null: false, precision: 6

      definition.index :message_id, unique: true, name: "idx_so_claimed_message"
      definition.index :instance_id, unique: true, name: "idx_so_claimed_instance"
      definition.index [ :process_id, :claimed_at ], name: "idx_so_claimed_process"
      definition.check_constraint "activation_generation > 0", name: "chk_so_claimed_generation"
    end

    add_foreign_key table(:claimed_messages),
      table(:processes),
      column: :process_id,
      on_delete: :nullify,
      name: "fk_so_claimed_process"
  end

  # @rbs () -> void
  def create_reminders
    create_table table(:reminders) do |definition|
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_reminders_instance" }
      definition.string :actor_type, null: false, limit: 191
      definition.string :actor_id, null: false, limit: 191
      definition.string :name, null: false, limit: 191
      definition.string :message_name, null: false, limit: 191
      json_column definition, :arguments, null: false
      definition.datetime :next_run_at, null: false, precision: 6
      definition.decimal :interval_seconds, precision: 20, scale: 6
      definition.bigint :occurrence, null: false, default: 0
      definition.string :missed_policy, null: false, default: "latest", limit: 32
      definition.string :status, null: false, default: "scheduled", limit: 32
      definition.string :claimed_by, limit: 36
      definition.datetime :claimed_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index [ :instance_id, :name ], unique: true, name: "idx_so_reminders_name"
      definition.index [ :status, :next_run_at, :id ], name: "idx_so_reminders_due"
      definition.check_constraint "occurrence >= 0", name: "chk_so_reminders_occurrence"
      definition.check_constraint "interval_seconds IS NULL OR interval_seconds > 0",
        name: "chk_so_reminders_interval"
      definition.check_constraint "missed_policy IN ('latest', 'all')",
        name: "chk_so_reminders_missed"
      definition.check_constraint "status IN ('scheduled', 'paused', 'completed')", name: "chk_so_reminders_status"
    end

    add_foreign_key table(:reminders),
      table(:processes),
      column: :claimed_by,
      on_delete: :nullify,
      name: "fk_so_reminders_process"
  end

  # @rbs () -> void
  def create_effects
    create_table table(:effects) do |definition|
      definition.references :message,
        null: false,
        foreign_key: { to_table: table(:messages), on_delete: :cascade, name: "fk_so_effects_message" }
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_effects_instance" }
      definition.string :effect_id, null: false, limit: 36
      definition.string :name, null: false, limit: 191
      json_column definition, :arguments, null: false
      definition.string :success_message_name, limit: 191
      definition.string :failure_message_name, limit: 191
      definition.string :status, null: false, default: "pending", limit: 32
      definition.integer :attempt_count, null: false, default: 0
      definition.integer :max_attempts, null: false
      definition.datetime :available_at, null: false, precision: 6
      definition.string :claimed_by, limit: 36
      definition.datetime :claimed_at, precision: 6
      json_column definition, :result
      json_column definition, :error
      definition.datetime :completed_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index :effect_id, unique: true, name: "idx_so_effects_effect_id"
      definition.index [ :status, :available_at, :id ], name: "idx_so_effects_poll"
      definition.index [ :completed_at, :id ], name: "idx_so_effects_cleanup"
      definition.check_constraint "attempt_count >= 0", name: "chk_so_effects_attempt"
      definition.check_constraint "max_attempts > 0", name: "chk_so_effects_max_attempts"
      definition.check_constraint "status IN ('pending', 'processing', 'completed', 'dead')", name: "chk_so_effects_status"
    end

    add_foreign_key table(:effects),
      table(:processes),
      column: :claimed_by,
      on_delete: :nullify,
      name: "fk_so_effects_process"
  end

  # @rbs () -> void
  def create_broadcasts
    create_table table(:broadcasts) do |definition|
      definition.references :message,
        null: false,
        foreign_key: { to_table: table(:messages), on_delete: :cascade, name: "fk_so_broadcasts_message" }
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_broadcasts_instance" }
      definition.string :broadcast_id, null: false, limit: 36
      definition.string :observable_name, null: false, limit: 191
      json_column definition, :value, null: false
      definition.integer :state_version, null: false
      definition.bigint :activation_generation, null: false
      definition.string :status, null: false, default: "pending", limit: 32
      definition.integer :attempt_count, null: false, default: 0
      definition.datetime :available_at, null: false, precision: 6
      definition.string :claimed_by, limit: 36
      definition.datetime :claimed_at, precision: 6
      json_column definition, :error
      definition.datetime :delivered_at, precision: 6
      definition.timestamps precision: 6, null: false

      definition.index :broadcast_id, unique: true, name: "idx_so_broadcasts_id"
      definition.index [ :message_id, :observable_name ], unique: true, name: "idx_so_broadcasts_observable"
      definition.index [ :status, :available_at, :id ], name: "idx_so_broadcasts_poll"
      definition.index [ :claimed_by, :claimed_at ], name: "idx_so_broadcasts_claim"
      definition.index [ :delivered_at, :id ], name: "idx_so_broadcasts_cleanup"
      definition.check_constraint "state_version > 0", name: "chk_so_broadcasts_version"
      definition.check_constraint "activation_generation > 0", name: "chk_so_broadcasts_generation"
      definition.check_constraint "attempt_count >= 0", name: "chk_so_broadcasts_attempt"
      definition.check_constraint "status IN ('pending', 'processing', 'delivered', 'dead')", name: "chk_so_broadcasts_status"
    end

    add_foreign_key table(:broadcasts),
      table(:processes),
      column: :claimed_by,
      on_delete: :nullify,
      name: "fk_so_broadcast_process"
  end

  # @rbs () -> void
  def create_dead_letters
    create_table table(:dead_letters) do |definition|
      definition.references :message,
        null: false,
        foreign_key: { to_table: table(:messages), on_delete: :cascade, name: "fk_so_dead_letters_message" }
      definition.references :instance,
        null: false,
        foreign_key: { to_table: table(:instances), on_delete: :cascade, name: "fk_so_dead_letters_instance" }
      definition.string :actor_type, null: false, limit: 191
      definition.string :actor_id, null: false, limit: 191
      definition.string :message_name, null: false, limit: 191
      json_column definition, :arguments, null: false
      definition.integer :attempts, null: false
      definition.string :exception_class, null: false, limit: 255
      definition.text :exception_message, null: false
      json_column definition, :backtrace, null: false
      definition.datetime :first_failed_at, null: false, precision: 6
      definition.datetime :last_failed_at, null: false, precision: 6
      definition.bigint :retried_message_id
      definition.timestamps precision: 6, null: false

      definition.index :message_id, unique: true, name: "idx_so_dead_letters_message"
      definition.index [ :actor_type, :actor_id, :last_failed_at ], name: "idx_so_dead_letters_actor"
      definition.index [ :last_failed_at, :id ], name: "idx_so_dead_letters_cleanup"
      definition.check_constraint "attempts > 0", name: "chk_so_dead_letters_attempts"
    end

    add_foreign_key table(:dead_letters),
      table(:messages),
      column: :retried_message_id,
      on_delete: :nullify,
      name: "fk_so_dead_letters_retry"
  end
end
