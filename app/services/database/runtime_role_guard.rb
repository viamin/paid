# frozen_string_literal: true

module Database
  class RuntimeRoleGuard # @spec POSTGRESQL-PERSISTENCE-002
    SKIP_ENV = "PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD"
    CREATE_DATABASE_TASKS = %w[
      db:create
      db:drop
      db:prepare
      db:reset
      db:setup
    ].freeze
    BUILD_TIME_TASKS = %w[
      assets:precompile
      bootsnap:precompile
    ].freeze

    class << self
      def verify!
        return if disabled?
        return unless postgresql?

        role = runtime_role
        return unless role

        unsafe_flags = unsafe_flags_for(role)
        return if unsafe_flags.empty?

        raise <<~MSG.squish
          Unsafe PostgreSQL runtime role #{role["rolname"].inspect}: #{unsafe_flags.to_sentence}.
          Tenant row-level security is bypassed by superusers and roles with BYPASSRLS.
          Configure DATABASE_URL to use a dedicated application role without SUPERUSER or BYPASSRLS.
        MSG
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        raise unless creating_database?
      end

      def disabled?
        ENV[SKIP_ENV] == "true" || creating_database? || build_time?
      end

      private

      def postgresql?
        ActiveRecord::Base.connection_db_config.adapter == "postgresql"
      end

      def runtime_role
        ActiveRecord::Base.connection.select_one(<<~SQL.squish)
          SELECT rolname, rolsuper, rolbypassrls
          FROM pg_roles
          WHERE rolname = current_user
        SQL
      end

      def unsafe_flags_for(role)
        [
          ("SUPERUSER" if truthy?(role["rolsuper"])),
          ("BYPASSRLS" if truthy?(role["rolbypassrls"]))
        ].compact
      end

      def truthy?(value)
        value == true || value == "t" || value == "true"
      end

      def creating_database?
        task_names.any? { |task| CREATE_DATABASE_TASKS.include?(task) }
      end

      def build_time?
        ENV["SECRET_KEY_BASE_DUMMY"].present? ||
          task_names.any? { |task| BUILD_TIME_TASKS.include?(task) }
      end

      def task_names
        ARGV + rake_task_names
      end

      def rake_task_names
        return [] unless defined?(Rake.application)

        Rake.application.top_level_tasks
      end
    end
  end
end
