# frozen_string_literal: true

module MigrationSpecHelpers
  def truncate_migration_test_data
    connection = ActiveRecord::Base.connection
    %w[
      feature_intent_forward_work_items
      feature_intent_completions
      feature_intent_issue_prerequisites
      feature_intent_issue_prerequisite_mappings
      feature_intent_issue_dependencies
      feature_intent_issues
      feature_intent_issue_publications
      feature_intent_facet_assessments
      feature_intent_facet_evidence
      feature_intent_facet_directions
      feature_intent_facets
      feature_intent_design_prs
      feature_intent_decisions
      feature_intent_approval_revisions
      feature_intents
      project_service_containers
      service_container_metrics
      service_containers
      workflow_states
      agent_run_resource_profiles
      agent_runs
      issues
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
