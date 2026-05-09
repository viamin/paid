# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260425060000_enable_rls_on_notification_rule_states")
require Rails.root.join("db/migrate/20260425113212_enable_rls_on_knowledge_usage_stats")
require Rails.root.join("db/migrate/20260426011810_enable_rls_on_llm_output_metrics")
require Rails.root.join("db/migrate/20260426231639_enable_rls_on_chat_tables")
require Rails.root.join("db/migrate/20260427225726_enable_rls_on_knowledge_recommendations")
require Rails.root.join("db/migrate/20260503093418_enable_rls_on_issue_merge_subscriptions")
require Rails.root.join("db/migrate/20260507224416_enable_rls_on_strategy_experiment_tables")
require Rails.root.join("db/migrate/20260507211918_enable_rls_on_strategies_and_strategy_versions")
require Rails.root.join("db/migrate/20260508014445_create_configuration_bundles")
require Rails.root.join("db/migrate/20260508020000_add_runtime_fields_to_configuration_bundles")

RSpec.describe EnableTenantRowLevelSecurity, :aggregate_failures do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:notification_rule_states_migration) { EnableRlsOnNotificationRuleStates.new }
  let(:knowledge_usage_stats_migration) { EnableRlsOnKnowledgeUsageStats.new }
  let(:llm_output_metrics_migration) { EnableRlsOnLlmOutputMetrics.new }
  let(:chat_tables_migration) { EnableRlsOnChatTables.new }
  let(:knowledge_recommendations_migration) { EnableRlsOnKnowledgeRecommendations.new }
  let(:issue_merge_subscriptions_migration) { EnableRlsOnIssueMergeSubscriptions.new }
  let(:strategy_experiment_tables_migration) { EnableRlsOnStrategyExperimentTables.new }
  let(:configuration_bundles_migration) { CreateConfigurationBundles.new }
  let(:configuration_bundle_runtime_fields_migration) { AddRuntimeFieldsToConfigurationBundles.new }

  around do |example|
    teardown_optimizer_tables
    rebuild_optimizer_tables
    disable_later_rls_migrations
    migration.down

    example.run
  ensure
    migration.down
    migration.up
    enable_later_rls_migrations
    rebuild_optimizer_tables unless optimizer_tables_present?
  end

  it "rebuilds policies for optimizer tables added by later migrations" do
    connection = ActiveRecord::Base.connection

    expect(connection.table_exists?(:configuration_bundles)).to be(true)
    expect(connection.table_exists?(:bundle_outcomes)).to be(true)

    expect { migration.up }.not_to raise_error
    expect(tenant_policy_count("configuration_bundles")).to be_positive
    expect(tenant_policy_count("bundle_outcomes")).to be_positive
  end

  private

  def strategy_rls_migration
    @strategy_rls_migration ||= EnableRlsOnStrategiesAndStrategyVersions.new
  end

  def tenant_policy_count(table_name)
    connection = ActiveRecord::Base.connection

    connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT COUNT(*)
          FROM pg_policies
          WHERE schemaname = 'public'
            AND tablename = ?
        SQL
        table_name
      ])
    ).to_i
  end

  def disable_later_rls_migrations
    strategy_rls_migration.down if strategies_have_rls?
    strategy_experiment_tables_migration.down if strategy_experiment_tables_have_rls?
    issue_merge_subscriptions_migration.down if issue_merge_subscriptions_have_rls?
    knowledge_recommendations_migration.down if knowledge_recommendations_has_rls?
    chat_tables_migration.down if chat_tables_have_rls?
    llm_output_metrics_migration.down if llm_output_metrics_have_rls?
    knowledge_usage_stats_migration.down if knowledge_usage_stats_have_rls?
    notification_rule_states_migration.down
  end

  def enable_later_rls_migrations
    notification_rule_states_migration.up
    knowledge_usage_stats_migration.up unless knowledge_usage_stats_have_rls?
    llm_output_metrics_migration.up unless llm_output_metrics_have_rls?
    chat_tables_migration.up unless chat_tables_have_rls?
    knowledge_recommendations_migration.up unless knowledge_recommendations_has_rls?
    issue_merge_subscriptions_migration.up unless issue_merge_subscriptions_have_rls?
    strategy_experiment_tables_migration.up unless strategy_experiment_tables_have_rls?
    strategy_rls_migration.up unless strategies_have_rls?
  end

  def issue_merge_subscriptions_have_rls?
    tenant_policy_count("issue_merge_subscriptions").positive?
  end

  def strategy_experiment_tables_have_rls?
    %w[
      strategy_experiments
      strategy_experiment_variants
      strategy_experiment_assignments
    ].all? { |table| tenant_policy_count(table).positive? }
  end

  def strategies_have_rls?
    %w[strategies strategy_versions].any? { |table| tenant_policy_count(table).positive? }
  end

  def knowledge_recommendations_has_rls?
    tenant_policy_count("knowledge_recommendations").positive?
  end

  def chat_tables_have_rls?
    %w[chat_sessions chat_messages chat_session_projects].all? { |table| tenant_policy_count(table).positive? }
  end

  def llm_output_metrics_have_rls?
    tenant_policy_count("llm_output_metrics").positive?
  end

  def knowledge_usage_stats_have_rls?
    tenant_policy_count("knowledge_usage_stats").positive?
  end

  def optimizer_tables_present?
    connection = ActiveRecord::Base.connection

    connection.table_exists?(:configuration_bundles) && connection.table_exists?(:bundle_outcomes)
  end

  def teardown_optimizer_tables
    connection = ActiveRecord::Base.connection

    configuration_bundle_runtime_fields_migration.down if connection.column_exists?(:agent_runs, :configuration_bundle_id)
    configuration_bundles_migration.down if optimizer_tables_present?
  end

  def rebuild_optimizer_tables
    connection = ActiveRecord::Base.connection

    configuration_bundles_migration.up unless optimizer_tables_present?
    configuration_bundle_runtime_fields_migration.up unless connection.column_exists?(:agent_runs, :configuration_bundle_id)
  end
end
