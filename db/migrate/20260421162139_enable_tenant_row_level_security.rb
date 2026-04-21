class EnableTenantRowLevelSecurity < ActiveRecord::Migration[8.1]
  DIRECT_ACCOUNT_TABLES = %w[
    account_memberships
    billing_invoices
    billing_periods
    billing_plans
    github_tokens
    integration_credentials
    linear_tokens
    mcp_server_definitions
    notifications
    onboarding_steps
    pr_templates
    pre_commit_requirements
    projects
    service_containers
    tenant_settings
    users
  ].freeze

  OPTIONAL_ACCOUNT_TABLES = %w[
    prompts
    style_guides
  ].freeze

  PROJECT_TABLES = %w[
    agent_run_anomalies
    agent_runs
    container_pool_entries
    context_intake_sessions
    cost_budgets
    decision_records
    issues
    knowledge_artifacts
    knowledge_audit_events
    knowledge_chunks
    knowledge_runs
    project_baselines
    project_mcp_servers
    project_memberships
    project_service_containers
    project_versions
    quality_gate_events
    quality_gate_thresholds
    quality_pause_events
    quality_recovery_actions
    workflow_states
    worktrees
  ].freeze

  AGENT_RUN_TABLES = %w[
    agent_run_logs
    agent_run_phases
    container_metrics
    model_selections
    quality_metrics
  ].freeze

  USER_TABLES = %w[
    provider_api_keys
    provider_states
    providers
    user_settings
  ].freeze

  PROMPT_TABLES = %w[
    ab_tests
    prompt_versions
  ].freeze

  def up
    create_helper_functions

    enable_policy("accounts", "id = paid_current_account_id()", insert_allows_missing_tenant: true)

    DIRECT_ACCOUNT_TABLES.each do |table|
      enable_policy(table, "#{table}.account_id = paid_current_account_id()")
    end

    OPTIONAL_ACCOUNT_TABLES.each do |table|
      enable_policy(table, "#{table}.account_id IS NULL OR #{table}.account_id = paid_current_account_id()")
    end

    PROJECT_TABLES.each do |table|
      enable_policy(table, project_condition(table))
    end

    AGENT_RUN_TABLES.each do |table|
      enable_policy(table, agent_run_condition(table))
    end

    USER_TABLES.each do |table|
      enable_policy(table, user_condition(table))
    end

    PROMPT_TABLES.each do |table|
      enable_policy(table, prompt_condition(table))
    end

    enable_policy("ab_test_variants", ab_test_condition("ab_test_variants"))
    enable_policy("ab_test_assignments", ab_test_assignment_condition)
    enable_policy("agent_coordination_signals", coordination_signal_condition)
    enable_policy("billing_line_items", billing_line_item_condition)
    enable_policy("collector_runs", collector_run_condition)
    enable_policy("context_intake_responses", context_intake_response_condition)
    enable_policy("decision_record_links", decision_record_link_condition)
    enable_policy("issue_dependencies", issue_dependency_condition)
    enable_policy("knowledge_links", knowledge_link_condition)
    enable_policy("service_container_metrics", service_container_metric_condition)
    enable_policy("token_usages", token_usage_condition)
    enable_policy("tracker_configurations", tracker_configuration_condition)
  end

  def down
    tenant_tables.each do |table|
      execute "DROP POLICY IF EXISTS tenant_isolation ON #{quote_table_name(table)}"
      execute "ALTER TABLE #{quote_table_name(table)} NO FORCE ROW LEVEL SECURITY"
      execute "ALTER TABLE #{quote_table_name(table)} DISABLE ROW LEVEL SECURITY"
    end

    execute "DROP FUNCTION IF EXISTS paid_tenant_bypass()"
    execute "DROP FUNCTION IF EXISTS paid_current_account_id()"
  end

  private

  def create_helper_functions
    execute <<~SQL
      CREATE OR REPLACE FUNCTION paid_current_account_id()
      RETURNS bigint
      LANGUAGE sql
      STABLE
      AS $$
        SELECT NULLIF(current_setting('paid.current_account_id', true), '')::bigint
      $$;
    SQL

    execute <<~SQL
      CREATE OR REPLACE FUNCTION paid_tenant_bypass()
      RETURNS boolean
      LANGUAGE sql
      STABLE
      AS $$
        SELECT current_setting('paid.bypass_tenant_rls', true) = 'true'
      $$;
    SQL
  end

  def enable_policy(table, condition, insert_allows_missing_tenant: false)
    qualified_table = quote_table_name(table)
    check_condition = insert_allows_missing_tenant ? "(#{condition} OR paid_current_account_id() IS NULL)" : condition

    execute "ALTER TABLE #{qualified_table} ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE #{qualified_table} FORCE ROW LEVEL SECURITY"
    execute <<~SQL
      CREATE POLICY tenant_isolation ON #{qualified_table}
      AS PERMISSIVE
      FOR ALL
      USING (paid_tenant_bypass() OR (#{condition}))
      WITH CHECK (paid_tenant_bypass() OR (#{check_condition}))
    SQL
  end

  def project_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM projects
        WHERE projects.id = #{table}.project_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def agent_run_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM agent_runs
        INNER JOIN projects ON projects.id = agent_runs.project_id
        WHERE agent_runs.id = #{table}.agent_run_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def user_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM users
        WHERE users.id = #{table}.user_id
          AND users.account_id = paid_current_account_id()
      )
    SQL
  end

  def prompt_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM prompts
        WHERE prompts.id = #{table}.prompt_id
          AND (prompts.account_id IS NULL OR prompts.account_id = paid_current_account_id())
      )
    SQL
  end

  def ab_test_condition(table)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM ab_tests
        INNER JOIN prompts ON prompts.id = ab_tests.prompt_id
        WHERE ab_tests.id = #{table}.ab_test_id
          AND (prompts.account_id IS NULL OR prompts.account_id = paid_current_account_id())
      )
    SQL
  end

  def ab_test_assignment_condition
    <<~SQL.squish
      #{ab_test_condition("ab_test_assignments")}
      AND #{agent_run_condition("ab_test_assignments")}
    SQL
  end

  def coordination_signal_condition
    <<~SQL.squish
      #{agent_run_condition_for("agent_coordination_signals", "source_agent_run_id")}
      AND (
        agent_coordination_signals.target_agent_run_id IS NULL
        OR #{agent_run_condition_for("agent_coordination_signals", "target_agent_run_id")}
      )
    SQL
  end

  def agent_run_condition_for(table, column)
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM agent_runs
        INNER JOIN projects ON projects.id = agent_runs.project_id
        WHERE agent_runs.id = #{table}.#{column}
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def billing_line_item_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM billing_invoices
        WHERE billing_invoices.id = billing_line_items.billing_invoice_id
          AND billing_invoices.account_id = paid_current_account_id()
      )
    SQL
  end

  def collector_run_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM project_versions
        INNER JOIN projects ON projects.id = project_versions.project_id
        WHERE project_versions.id = collector_runs.project_version_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def context_intake_response_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM context_intake_sessions
        INNER JOIN projects ON projects.id = context_intake_sessions.project_id
        WHERE context_intake_sessions.id = context_intake_responses.context_intake_session_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def decision_record_link_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM decision_records
        INNER JOIN projects ON projects.id = decision_records.project_id
        WHERE decision_records.id = decision_record_links.decision_record_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def issue_dependency_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM issues
        INNER JOIN projects ON projects.id = issues.project_id
        WHERE issues.id = issue_dependencies.issue_id
          AND projects.account_id = paid_current_account_id()
      )
      AND (
        issue_dependencies.depends_on_issue_id IS NULL
        OR EXISTS (
          SELECT 1 FROM issues depends_on_issues
          INNER JOIN projects ON projects.id = depends_on_issues.project_id
          WHERE depends_on_issues.id = issue_dependencies.depends_on_issue_id
            AND projects.account_id = paid_current_account_id()
        )
      )
    SQL
  end

  def knowledge_link_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM knowledge_chunks
        INNER JOIN projects ON projects.id = knowledge_chunks.project_id
        WHERE knowledge_chunks.id = knowledge_links.source_chunk_id
          AND projects.account_id = paid_current_account_id()
      )
      AND EXISTS (
        SELECT 1 FROM knowledge_chunks
        INNER JOIN projects ON projects.id = knowledge_chunks.project_id
        WHERE knowledge_chunks.id = knowledge_links.target_chunk_id
          AND projects.account_id = paid_current_account_id()
      )
    SQL
  end

  def service_container_metric_condition
    <<~SQL.squish
      EXISTS (
        SELECT 1 FROM service_containers
        WHERE service_containers.id = service_container_metrics.service_container_id
          AND service_containers.account_id = paid_current_account_id()
      )
    SQL
  end

  def token_usage_condition
    <<~SQL.squish
      (
        token_usages.agent_run_id IS NOT NULL
        AND #{agent_run_condition("token_usages")}
      )
      OR (
        token_usages.knowledge_run_id IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM knowledge_runs
          INNER JOIN projects ON projects.id = knowledge_runs.project_id
          WHERE knowledge_runs.id = token_usages.knowledge_run_id
            AND projects.account_id = paid_current_account_id()
        )
      )
    SQL
  end

  def tracker_configuration_condition
    <<~SQL.squish
      (
        tracker_configurations.configurable_type = 'Account'
        AND tracker_configurations.configurable_id = paid_current_account_id()
      )
      OR (
        tracker_configurations.configurable_type = 'Project'
        AND EXISTS (
          SELECT 1 FROM projects
          WHERE projects.id = tracker_configurations.configurable_id
            AND projects.account_id = paid_current_account_id()
        )
      )
    SQL
  end

  def tenant_tables
    [
      "accounts",
      *DIRECT_ACCOUNT_TABLES,
      *OPTIONAL_ACCOUNT_TABLES,
      *PROJECT_TABLES,
      *AGENT_RUN_TABLES,
      *USER_TABLES,
      *PROMPT_TABLES,
      "ab_test_variants",
      "ab_test_assignments",
      "agent_coordination_signals",
      "billing_line_items",
      "collector_runs",
      "context_intake_responses",
      "decision_record_links",
      "issue_dependencies",
      "knowledge_links",
      "service_container_metrics",
      "token_usages",
      "tracker_configurations"
    ].uniq
  end
end
