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
      providers
      provider_states
      account_memberships
      github_tokens
      users
      accounts
    ].each { |table| connection.execute("DELETE FROM #{table}") }
  end
end
