# rbs_inline: enabled

module SolidObjects
  module WakeUpAdapters
    module_function

    # Returns the best wake-up strategy for a connection: cross-process
    # notifications where the database provides them, and the in-process
    # default everywhere else.
    #
    # This is deliberately not the default. A notification adapter opens a
    # connection per waiting thread outside the pool, and `LISTEN` does not
    # survive a transaction-pooling proxy such as PgBouncer, so adopting it is
    # a deployment decision rather than an upgrade side effect.
    #
    # @rbs (?untyped) -> untyped
    def for(connection = Record.connection)
      return Postgresql.new if DatabaseAdapter.family(connection) == :postgresql

      WakeUp.new
    end
  end
end
