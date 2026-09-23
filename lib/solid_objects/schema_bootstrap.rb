# rbs_inline: enabled

require "active_record"
require "active_support/core_ext/string/inflections"

module SolidObjects
  module SchemaBootstrap
    class << self
      # @rbs (?connection: untyped) -> void
      def install(connection: nil)
        migrations.each do |migration_class|
          migration = migration_class.new
          migration.define_singleton_method(:connection) { connection } if connection
          migration.migrate(:up)
        end
      end

      # @rbs () -> Array[Class]
      def migrations
        Dir[File.expand_path("../../db/migrate/*.rb", __dir__)].sort.map do |file|
          require file
          Object.const_get(File.basename(file, ".rb").sub(/\A\d+_/, "").camelize)
        end
      end
    end
  end
end
