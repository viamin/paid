# frozen_string_literal: true

module MigrationSpecHelpers
  def truncate_migration_test_data
    connection = ActiveRecord::Base.connection
    %w[
      project_service_containers
      service_container_metrics
      service_containers
      workflow_states
      projects
      runners
      runner_states
      account_memberships
      github_tokens
      user_settings
      tenant_settings
      users
      accounts
    ].each { |table| connection.execute("DELETE FROM #{table}") }
  end
end
