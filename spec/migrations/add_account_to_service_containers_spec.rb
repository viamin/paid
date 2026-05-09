# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421162135_add_account_to_service_containers")
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260425113212_enable_rls_on_knowledge_usage_stats")
require Rails.root.join("db/migrate/20260425060000_enable_rls_on_notification_rule_states")
require Rails.root.join("db/migrate/20260426011810_enable_rls_on_llm_output_metrics")
require Rails.root.join("db/migrate/20260426231639_enable_rls_on_chat_tables")
require Rails.root.join("db/migrate/20260427225726_enable_rls_on_knowledge_recommendations")
require Rails.root.join("db/migrate/20260428140000_create_exception_incidents")
require Rails.root.join("db/migrate/20260503093418_enable_rls_on_issue_merge_subscriptions")
require Rails.root.join("db/migrate/20260508120219_create_failure_classifications")
require Rails.root.join("db/migrate/20260507125050_create_decomposition_decisions")
require Rails.root.join("db/migrate/20260507164917_create_orchestration_decisions")
require Rails.root.join("db/migrate/20260507202027_add_strategy_version_to_orchestration_decisions")
require Rails.root.join("db/migrate/20260507211918_enable_rls_on_strategies_and_strategy_versions")
require Rails.root.join("db/migrate/20260507224416_enable_rls_on_strategy_experiment_tables")
require Rails.root.join("db/migrate/20260508064240_tighten_orchestration_decisions_strategy_version_tenant_check")
require Rails.root.join("db/migrate/20260509083302_ensure_strategy_version_id_on_orchestration_decisions")

RSpec.describe AddAccountToServiceContainers, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:rls_migration) { EnableTenantRowLevelSecurity.new }
  let(:knowledge_rls_migration) { EnableRlsOnKnowledgeUsageStats.new }
  let(:notification_rls_migration) { EnableRlsOnNotificationRuleStates.new }
  let(:llm_output_metrics_rls_migration) { EnableRlsOnLlmOutputMetrics.new }
  let(:chat_rls_migration) { EnableRlsOnChatTables.new }
  let(:knowledge_recommendations_rls_migration) { EnableRlsOnKnowledgeRecommendations.new }
  let(:issue_merge_subscriptions_rls_migration) { EnableRlsOnIssueMergeSubscriptions.new }
  let(:strategy_rls_migration) { EnableRlsOnStrategiesAndStrategyVersions.new }

  include MigrationSpecHelpers

  before do
    truncate_migration_test_data

    if tenant_policy_count.positive?
      tighten_orchestration_decisions_strategy_version_tenant_check_migration.down if orchestration_decisions_have_strategy_version_reference?
      add_strategy_version_to_orchestration_decisions_migration.migrate(:down) if orchestration_decisions_have_strategy_version_reference?
      strategy_rls_migration.down if strategies_have_rls?
      strategy_experiments_rls_migration.down if strategy_experiment_tables_have_rls?
      orchestration_decisions_migration.down if orchestration_decisions_table_exists?
      disable_decomposition_decisions_rls if decomposition_decisions_have_rls?
      exception_incidents_migration.down if exception_incidents_table_exists?
      issue_merge_subscriptions_rls_migration.down if issue_merge_subscriptions_have_rls?
      knowledge_recommendations_rls_migration.down if knowledge_recommendations_has_rls?
      chat_rls_migration.down if chat_tables_have_rls?
      llm_output_metrics_rls_migration.down if llm_output_metrics_has_rls?
      knowledge_rls_migration.down if knowledge_usage_stats_has_rls?
      notification_rls_migration.down
      failure_classifications_migration.down if failure_classifications_table_exists?
      rls_migration.down
    end
    restore_service_container_account_reference unless service_containers_have_account_reference?
    migration.down
    ServiceContainer.reset_column_information
    OrchestrationDecision.reset_column_information
  end

  after do
    truncate_migration_test_data

    restore_service_container_account_reference unless service_containers_have_account_reference?
    if tenant_policy_count.zero?
      rls_migration.up
      notification_rls_migration.up
      knowledge_rls_migration.up unless knowledge_usage_stats_has_rls?
      llm_output_metrics_rls_migration.up unless llm_output_metrics_has_rls?
      chat_rls_migration.up unless chat_tables_have_rls?
      knowledge_recommendations_rls_migration.up unless knowledge_recommendations_has_rls?
      issue_merge_subscriptions_rls_migration.up unless issue_merge_subscriptions_have_rls?
      exception_incidents_migration.up unless exception_incidents_table_exists?
      failure_classifications_migration.up unless failure_classifications_table_exists?
      orchestration_decisions_migration.up unless orchestration_decisions_table_exists?
      add_strategy_version_to_orchestration_decisions_migration.migrate(:up) unless orchestration_decisions_have_strategy_version_reference?
      ensure_strategy_version_id_on_orchestration_decisions unless orchestration_decisions_have_strategy_version_reference?
      tighten_orchestration_decisions_strategy_version_tenant_check_migration.up if orchestration_decisions_have_strategy_version_reference?
      strategy_experiments_rls_migration.up unless strategy_experiment_tables_have_rls?
      strategy_rls_migration.up unless strategies_have_rls?
    end
    OrchestrationDecision.reset_column_information
    ServiceContainer.reset_column_information
  end

  it "duplicates shared service containers per account and rewires project joins" do
    first_project, second_project, service_container = create_shared_service_container

    migration.up
    ServiceContainer.reset_column_information

    first_project_service_container = project_service_container_for(first_project)
    second_project_service_container = project_service_container_for(second_project)

    expect(first_project_service_container.account_id).to eq(first_project.account_id)
    expect(second_project_service_container.account_id).to eq(second_project.account_id)
    expect(first_project_service_container.name).to eq(service_container["name"])
    expect(second_project_service_container.name).to eq(service_container["name"])
    expect(first_project_service_container.id).not_to eq(second_project_service_container.id)
    expect(first_project_service_container.status).to eq("running")
    expect(first_project_service_container.docker_container_id).to eq("container-1")
    expect(second_project_service_container.status).to eq("stopped")
    expect(second_project_service_container.docker_container_id).to be_nil
    expect(metric_count_for(first_project_service_container)).to eq(1)
    expect(metric_count_for(second_project_service_container)).to eq(1)
  end

  it "collapses per-account copies before restoring the global name index on rollback" do
    create_shared_service_container

    migration.up

    expect { migration.down }.not_to raise_error
    ServiceContainer.reset_column_information

    expect(service_container_count).to eq(1)
    expect(service_container_metric_count).to eq(1)
    expect(project_service_container_count).to eq(2)
    expect(distinct_joined_service_container_count).to eq(1)
  end

  private

  def create_shared_service_container
    first_project = create(:project)
    second_project = create(:project)
    service_container = create_service_container_without_account

    create_project_service_container(first_project, service_container)
    create_project_service_container(second_project, service_container)
    create_service_container_metric(service_container)

    [ first_project, second_project, service_container ]
  end

  def create_service_container_without_account
    result = ActiveRecord::Base.connection.exec_query(<<~SQL.squish)
      INSERT INTO service_containers (
        image,
        name,
        port,
        env,
        docker_container_id,
        status,
        created_at,
        updated_at
      )
      VALUES (
        'postgres:16',
        'shared-postgres',
        5432,
        '{"POSTGRES_USER":"agent"}',
        'container-1',
        'running',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
      RETURNING id, name
    SQL

    result.first
  end

  def create_project_service_container(project, service_container)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_service_containers (
        project_id,
        service_container_id,
        created_at,
        updated_at
      )
      VALUES (
        #{project.id},
        #{service_container["id"]},
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def create_service_container_metric(service_container)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO service_container_metrics (
        service_container_id,
        container_id,
        cpu_percent,
        memory_bytes,
        memory_limit_bytes,
        memory_percent,
        recorded_at,
        created_at,
        updated_at
      )
      VALUES (
        #{service_container["id"]},
        'container-1',
        1.5,
        1024,
        2048,
        50.0,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def project_service_container_for(project)
    project.service_containers.reload.sole
  end

  def metric_count_for(service_container)
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT COUNT(*)
      FROM service_container_metrics
      WHERE service_container_id = #{service_container.id}
    SQL
  end

  def service_container_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM service_containers")
  end

  def service_container_metric_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM service_container_metrics")
  end

  def project_service_container_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM project_service_containers")
  end

  def distinct_joined_service_container_count
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(DISTINCT service_container_id) FROM project_service_containers"
    )
  end

  def knowledge_recommendations_has_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'knowledge_recommendations' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def knowledge_usage_stats_has_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'knowledge_usage_stats' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def chat_tables_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'chat_sessions' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def llm_output_metrics_has_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'llm_output_metrics' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def issue_merge_subscriptions_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'issue_merge_subscriptions' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def strategies_have_rls?
    ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*)
      FROM pg_policies
      WHERE policyname IN (
        'tenant_isolation',
        'tenant_isolation_select',
        'tenant_isolation_insert',
        'tenant_isolation_update',
        'tenant_isolation_delete'
      )
        AND tablename IN ('strategies', 'strategy_versions')
    SQL
  end

  def strategy_experiment_tables_have_rls?
    ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i == 3
      SELECT COUNT(*)
      FROM pg_policies
      WHERE policyname = 'tenant_isolation'
        AND tablename IN ('strategy_experiments', 'strategy_experiment_variants', 'strategy_experiment_assignments')
    SQL
  end

  def exception_incidents_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'exception_incidents' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def exception_incidents_table_exists?
    ActiveRecord::Base.connection.table_exists?(:exception_incidents)
  end

  def failure_classifications_table_exists?
    ActiveRecord::Base.connection.table_exists?(:failure_classifications)
  end

  def decomposition_decisions_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'decomposition_decisions' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def disable_decomposition_decisions_rls
    ActiveRecord::Base.connection.execute("DROP POLICY IF EXISTS tenant_isolation ON decomposition_decisions")
    ActiveRecord::Base.connection.execute("ALTER TABLE decomposition_decisions NO FORCE ROW LEVEL SECURITY")
    ActiveRecord::Base.connection.execute("ALTER TABLE decomposition_decisions DISABLE ROW LEVEL SECURITY")
  end

  def orchestration_decisions_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'orchestration_decisions' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def orchestration_decisions_table_exists?
    ActiveRecord::Base.connection.table_exists?(:orchestration_decisions)
  end

  def orchestration_decisions_have_strategy_version_reference?
    orchestration_decisions_table_exists? &&
      ActiveRecord::Base.connection.column_exists?(:orchestration_decisions, :strategy_version_id)
  end

  def exception_incidents_migration
    @exception_incidents_migration ||= CreateExceptionIncidents.new
  end

  def failure_classifications_migration
    @failure_classifications_migration ||= CreateFailureClassifications.new
  end

  def orchestration_decisions_migration
    @orchestration_decisions_migration ||= CreateOrchestrationDecisions.new
  end

  def add_strategy_version_to_orchestration_decisions_migration
    @add_strategy_version_to_orchestration_decisions_migration ||= AddStrategyVersionToOrchestrationDecisions.new
  end

  def tighten_orchestration_decisions_strategy_version_tenant_check_migration
    @tighten_orchestration_decisions_strategy_version_tenant_check_migration ||=
      TightenOrchestrationDecisionsStrategyVersionTenantCheck.new
  end

  def ensure_strategy_version_id_on_orchestration_decisions
    connection = ActiveRecord::Base.connection
    return if connection.column_exists?(:orchestration_decisions, :strategy_version_id)

    connection.execute("ALTER TABLE orchestration_decisions ADD COLUMN strategy_version_id bigint")
    connection.execute("CREATE INDEX IF NOT EXISTS index_orchestration_decisions_on_strategy_version_id ON orchestration_decisions (strategy_version_id)")
    if connection.table_exists?(:strategy_versions)
      connection.execute(<<~SQL.squish)
        ALTER TABLE orchestration_decisions
        ADD CONSTRAINT fk_orchestration_decisions_strategy_version
        FOREIGN KEY (strategy_version_id) REFERENCES strategy_versions(id) ON DELETE SET NULL
      SQL
    end
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn(message: "ensure_strategy_version_id_failed", error: e.message)
  end

  def strategy_experiments_rls_migration
    @strategy_experiments_rls_migration ||= EnableRlsOnStrategyExperimentTables.new
  end

  def tenant_policy_count
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE policyname = 'tenant_isolation'"
    ).to_i
  end

  def service_containers_have_account_reference?
    connection = ActiveRecord::Base.connection
    connection.column_exists?(:service_containers, :account_id) &&
      connection.foreign_key_exists?(:service_containers, :accounts)
  end

  def restore_service_container_account_reference
    connection = ActiveRecord::Base.connection
    connection.remove_index(:service_containers, column: [ :account_id, :name ], if_exists: true)
    connection.remove_column(:service_containers, :account_id) if connection.column_exists?(:service_containers, :account_id)
    migration.up
  end
end
