# frozen_string_literal: true

# Back up dev/test databases before destructive Rails db tasks and before any
# schema reload / purge / truncate, so neither `bin/rails db:reset` nor a stray
# DatabaseTasks.load_schema / purge / truncate_tables call can destroy data
# without a snapshot to roll back to. See Database::SafetyBackup for the policy.
#
# The hook module is defined here (rather than under app/services) so it is not
# subject to development auto-reload, which would detach it from the prepended
# ActiveRecord::Tasks::DatabaseTasks and silently disable the guard.
module DatabaseSafetyBackupHook
  def load_schema(db_config, *rest)
    Database::SafetyBackup.snapshot_if_populated!(config_for(db_config))
    super
  end

  def purge(db_config, *rest)
    Database::SafetyBackup.snapshot_if_populated!(config_for(db_config))
    super
  end

  def truncate_tables(db_config, *rest)
    Database::SafetyBackup.snapshot_if_populated!(config_for(db_config))
    super
  end

  private

  def config_for(arg)
    return arg if arg.respond_to?(:database)

    ActiveRecord::Base.configurations.resolve(arg.to_s)
  rescue StandardError
    arg
  end
end

Rails.application.config.after_initialize do
  next if Rails.env.production?

  tasks = ActiveRecord::Tasks::DatabaseTasks
  tasks.prepend(DatabaseSafetyBackupHook) unless tasks.ancestors.include?(DatabaseSafetyBackupHook)

  Database::SafetyBackup.backup_before_destructive!
end
