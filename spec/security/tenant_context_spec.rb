# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260425113212_enable_rls_on_knowledge_usage_stats")
require Rails.root.join("db/migrate/20260425060000_enable_rls_on_notification_rule_states")
require Rails.root.join("db/migrate/20260426011810_enable_rls_on_llm_output_metrics")
require Rails.root.join("db/migrate/20260426231639_enable_rls_on_chat_tables")
require Rails.root.join("db/migrate/20260427225726_enable_rls_on_knowledge_recommendations")
require Rails.root.join("db/migrate/20260503093418_enable_rls_on_issue_merge_subscriptions")
require Rails.root.join("db/migrate/20260428140000_create_exception_incidents")
require Rails.root.join("db/migrate/20260508120219_create_failure_classifications")
require Rails.root.join("db/migrate/20260507125050_create_decomposition_decisions")
require Rails.root.join("db/migrate/20260507164917_create_orchestration_decisions")
require Rails.root.join("db/migrate/20260507202027_add_strategy_version_to_orchestration_decisions")
require Rails.root.join("db/migrate/20260507211918_enable_rls_on_strategies_and_strategy_versions")
require Rails.root.join("db/migrate/20260507224416_enable_rls_on_strategy_experiment_tables")
require Rails.root.join("db/migrate/20260508064240_tighten_orchestration_decisions_strategy_version_tenant_check")

RSpec.describe TenantContext, :tenant_isolation do
  around do |example|
    setup_complete = false

    skip "requires CREATE ROLE privilege for RLS policy checks" unless can_manage_roles?

    install_tenant_policies
    setup_complete = true
    example.run
  ensure
    uninstall_tenant_policies if setup_complete
  end

  let(:account_a) { create(:account) }
  let(:account_b) { create(:account) }

  it "filters direct account records through the database policy" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    described_class.with_system_access { create(:project, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect(Project.all).to contain_exactly(project_a)
      end
    end
  end

  it "filters project-owned records through the database policy" do
    run_a = described_class.with_system_access { create(:agent_run, project: create(:project, account: account_a)) }
    described_class.with_system_access { create(:agent_run, project: create(:project, account: account_b)) }

    as_restricted_role do
      described_class.with(account_a) do
        expect(AgentRun.all).to contain_exactly(run_a)
      end
    end
  end

  it "filters configuration bundles and outcomes through the database policy" do
    bundle_a, outcome_a = described_class.with_system_access do
      project = create(:project, account: account_a)
      bundle = create(:configuration_bundle, account: account_a, project: project)
      run = create(:agent_run, :completed, project: project, issue: create(:issue, project: project), configuration_bundle: bundle)

      [ bundle, create(:bundle_outcome, configuration_bundle: bundle, agent_run: run) ]
    end
    described_class.with_system_access do
      project = create(:project, account: account_b)
      bundle = create(:configuration_bundle, account: account_b, project: project)
      run = create(:agent_run, :completed, project: project, issue: create(:issue, project: project), configuration_bundle: bundle)
      create(:bundle_outcome, configuration_bundle: bundle, agent_run: run)
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect(ConfigurationBundle.all).to contain_exactly(bundle_a)
        expect(BundleOutcome.all).to contain_exactly(outcome_a)
      end
    end
  end

  it "filters issue merge subscriptions and rejects cross-tenant users at the database policy" do
    subscription_a = described_class.with_system_access do
      issue = create(:issue, project: create(:project, account: account_a))
      create(:issue_merge_subscription, issue:)
    end
    issue_a = subscription_a.issue
    user_b = described_class.with_system_access { create(:user, account: account_b) }
    described_class.with_system_access do
      create(:issue_merge_subscription, issue: create(:issue, project: create(:project, account: account_b)))
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect(IssueMergeSubscription.all).to contain_exactly(subscription_a)
        expect_rls_rejection { insert_issue_merge_subscription(issue_a, user_b) }
      end
    end
  end

  it "does not return tenant rows without tenant context" do
    described_class.with_system_access { create(:project, account: account_a) }

    as_restricted_role do
      described_class.clear!
      expect(Project.all).to be_empty
    end
  end

  it "uses tenant-specific Qdrant collection names" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    project_b = described_class.with_system_access { create(:project, account: account_b) }

    expect(Knowledge::Qdrant::CollectionManager.collection_name(project_a))
      .to eq("account_#{account_a.id}_project_#{project_a.id}")
    expect(Knowledge::Qdrant::CollectionManager.collection_name(project_b))
      .to eq("account_#{account_b.id}_project_#{project_b.id}")
  end

  it "rejects cross-tenant project join rows at the database policy" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    user_b = described_class.with_system_access { create(:user, account: account_b) }
    mcp_server_b = described_class.with_system_access { create(:mcp_server_definition, account: account_b) }
    service_container_b = described_class.with_system_access { create(:service_container, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect_rls_rejection { insert_project_membership(project_a, user_b) }
        expect_rls_rejection { insert_project_mcp_server(project_a, mcp_server_b) }
        expect_rls_rejection { insert_project_service_container(project_a, service_container_b) }
      end
    end
  end

  it "rejects direct account rows with cross-tenant references at the database policy" do
    account = described_class.with_system_access { account_a }
    project_b = described_class.with_system_access { create(:project, account: account_b) }
    user_b = described_class.with_system_access { create(:user, account: account_b) }

    as_restricted_role do
      described_class.with(account) do
        expect_rls_rejection { insert_account_membership(account, user_b) }
        expect_rls_rejection { insert_pr_template(account, project_id: project_b.id) }
        expect_rls_rejection { insert_pre_commit_requirement(account, user_id: user_b.id) }
        expect_rls_rejection { insert_quality_threshold(account, project_b) }
        expect_rls_rejection { insert_notification(account, user_b) }
        expect_rls_rejection { insert_github_token(account, user_b) }
      end
    end
  end

  it "rejects cross-tenant configuration bundle writes at the database policy" do
    account = described_class.with_system_access { account_a }
    project_b = described_class.with_system_access { create(:project, account: account_b) }

    as_restricted_role do
      described_class.with(account) do
        expect_rls_rejection { insert_configuration_bundle(account, project_id: project_b.id) }
      end
    end
  end

  it "allows tenant reads but blocks tenant writes for global prompts and style guides" do
    global_prompt = described_class.with_system_access { create(:prompt, :global, :with_version) }
    tenant_prompt = described_class.with_system_access { create(:prompt, :for_account, account: account_a) }
    global_style_guide = described_class.with_system_access { create(:style_guide, :global) }
    tenant_style_guide = described_class.with_system_access { create(:style_guide, :for_account, account: account_a) }

    as_restricted_role do
      described_class.with(account_a) do
        expect_optional_account_reads_allowed(global_prompt, tenant_prompt, global_style_guide, tenant_style_guide)
        expect_global_prompt_writes_blocked(global_prompt)
        expect_global_prompt_version_writes_blocked(global_prompt.current_version)
        expect_global_style_guide_writes_blocked(global_style_guide)
        expect_rls_rejection { insert_prompt(account_id: nil) }
        expect_rls_rejection { insert_prompt_version(prompt: global_prompt) }
        expect_rls_rejection { insert_style_guide(account_id: nil) }
      end
    end

    described_class.with_system_access do
      expect(global_prompt.reload.name).not_to eq("Changed Global Prompt")
      expect(global_style_guide.reload.name).not_to eq("Changed Global Guide")
    end
  end

  it "requires optional-account project writes to stay inside the tenant account" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    project_b = described_class.with_system_access { create(:project, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect { insert_prompt(account_id: account_a.id) }.not_to raise_error
        expect { insert_prompt(account_id: account_a.id, project_id: project_a.id) }.not_to raise_error
        tenant_prompt = described_class.with_system_access { create(:prompt, :for_account, account: account_a) }
        expect { insert_prompt_version(prompt: tenant_prompt) }.not_to raise_error
        expect { insert_style_guide(account_id: account_a.id) }.not_to raise_error
        expect { insert_style_guide(account_id: account_a.id, project_id: project_a.id) }.not_to raise_error
        expect_rls_rejection { insert_prompt(account_id: account_a.id, project_id: project_b.id) }
        expect_rls_rejection { insert_style_guide(account_id: account_a.id, project_id: project_b.id) }
      end
    end
  end

  it "rejects orchestration decisions that attach another account's strategy version" do
    project_a = described_class.with_system_access { create(:project, account: account_a) }
    strategy_version_b = described_class.with_system_access do
      create(:strategy_version, strategy: create(:strategy, :for_account, account: account_b))
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect_db_rejection(/strategy_version_id must reference a global or same-tenant strategy version/) do
          insert_orchestration_decision(project_a, strategy_version_b)
        end
      end
    end
  end

  def as_restricted_role
    ActiveRecord::Base.connection.execute("SET ROLE paid_rls_spec")
    yield
  ensure
    ActiveRecord::Base.connection.execute("RESET ROLE")
  end

  def install_tenant_policies
    ActiveRecord::Migration.suppress_messages do
      TightenOrchestrationDecisionsStrategyVersionTenantCheck.new.down if orchestration_decisions_have_rls?
      AddStrategyVersionToOrchestrationDecisions.new.migrate(:down) if orchestration_decisions_have_strategy_version_reference?
      EnableRlsOnStrategiesAndStrategyVersions.new.down if strategies_have_rls?
      EnableRlsOnStrategyExperimentTables.new.down if strategy_experiment_tables_have_rls?
      CreateOrchestrationDecisions.new.down if orchestration_decisions_table_exists?
      disable_decomposition_decisions_rls if decomposition_decisions_have_rls?
      CreateExceptionIncidents.new.down if exception_incidents_have_rls?
      EnableRlsOnKnowledgeRecommendations.new.down if knowledge_recommendations_has_rls?
      EnableRlsOnChatTables.new.down if chat_tables_have_rls?
      EnableRlsOnLlmOutputMetrics.new.down if llm_output_metrics_has_rls?
      EnableRlsOnKnowledgeUsageStats.new.down if knowledge_usage_stats_has_rls?
      EnableRlsOnNotificationRuleStates.new.down
      EnableRlsOnIssueMergeSubscriptions.new.down if issue_merge_subscriptions_has_rls?
      CreateFailureClassifications.new.down if failure_classifications_table_exists?
      EnableTenantRowLevelSecurity.new.down
      EnableTenantRowLevelSecurity.new.up
      EnableRlsOnNotificationRuleStates.new.up
      EnableRlsOnKnowledgeUsageStats.new.up unless knowledge_usage_stats_has_rls?
      EnableRlsOnLlmOutputMetrics.new.up unless llm_output_metrics_has_rls?
      EnableRlsOnChatTables.new.up unless chat_tables_have_rls?
      EnableRlsOnKnowledgeRecommendations.new.up unless knowledge_recommendations_has_rls?
      EnableRlsOnIssueMergeSubscriptions.new.up unless issue_merge_subscriptions_has_rls?
      CreateExceptionIncidents.new.up unless exception_incidents_table_exists?
      CreateFailureClassifications.new.up unless failure_classifications_table_exists?
      CreateOrchestrationDecisions.new.up unless orchestration_decisions_table_exists?
      AddStrategyVersionToOrchestrationDecisions.new.migrate(:up) unless orchestration_decisions_have_strategy_version_reference?
      TightenOrchestrationDecisionsStrategyVersionTenantCheck.new.up if orchestration_decisions_have_strategy_version_reference?
      EnableRlsOnStrategyExperimentTables.new.up unless strategy_experiment_tables_have_rls?
      EnableRlsOnStrategiesAndStrategyVersions.new.up unless strategies_have_rls?
    end
    ActiveRecord::Base.connection.execute("RESET ROLE")
    cleanup_restricted_role
    ActiveRecord::Base.connection.execute("CREATE ROLE paid_rls_spec NOLOGIN")
    ActiveRecord::Base.connection.execute("GRANT USAGE ON SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT paid_rls_spec TO current_user")
  end

  def uninstall_tenant_policies
    ActiveRecord::Base.connection.execute("RESET ROLE")
    cleanup_restricted_role
    ActiveRecord::Migration.suppress_messages do
      TightenOrchestrationDecisionsStrategyVersionTenantCheck.new.down if orchestration_decisions_have_rls?
      AddStrategyVersionToOrchestrationDecisions.new.migrate(:down) if orchestration_decisions_have_strategy_version_reference?
      EnableRlsOnStrategiesAndStrategyVersions.new.down if strategies_have_rls?
      EnableRlsOnStrategyExperimentTables.new.down if strategy_experiment_tables_have_rls?
      CreateOrchestrationDecisions.new.down if orchestration_decisions_table_exists?
      disable_decomposition_decisions_rls if decomposition_decisions_have_rls?
      CreateExceptionIncidents.new.down if exception_incidents_have_rls?
      EnableRlsOnKnowledgeRecommendations.new.down if knowledge_recommendations_has_rls?
      EnableRlsOnChatTables.new.down if chat_tables_have_rls?
      EnableRlsOnLlmOutputMetrics.new.down if llm_output_metrics_has_rls?
      EnableRlsOnKnowledgeUsageStats.new.down if knowledge_usage_stats_has_rls?
      EnableRlsOnNotificationRuleStates.new.down
      EnableRlsOnIssueMergeSubscriptions.new.down if issue_merge_subscriptions_has_rls?
      CreateFailureClassifications.new.down if failure_classifications_table_exists?
      EnableTenantRowLevelSecurity.new.down
    end
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

  def issue_merge_subscriptions_has_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'issue_merge_subscriptions' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
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
    ActiveRecord::Base.connection.execute("DROP POLICY IF EXISTS tenant_isolation ON decomposition_decidents")
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

  def strategy_experiment_tables_have_rls?
    ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i == 3
      SELECT COUNT(*)
      FROM pg_policies
      WHERE policyname = 'tenant_isolation'
        AND tablename IN ('strategy_experiments', 'strategy_experiment_variants', 'strategy_experiment_assignments')
    SQL
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

  def cleanup_restricted_role
    return unless ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = 'paid_rls_spec'")

    ActiveRecord::Base.connection.execute("GRANT paid_rls_spec TO current_user")
    ActiveRecord::Base.connection.execute("DROP OWNED BY paid_rls_spec")
    ActiveRecord::Base.connection.execute("DROP ROLE IF EXISTS paid_rls_spec")
  end

  def can_manage_roles?
    ActiveModel::Type::Boolean.new.cast(
      ActiveRecord::Base.connection.select_value(<<~SQL.squish)
        SELECT rolcreaterole
        FROM pg_roles
        WHERE rolname = current_user
      SQL
    )
  end

  def expect_rls_rejection
    ActiveRecord::Base.connection.execute("SAVEPOINT rls_rejection")
    expect { yield }.to raise_error(ActiveRecord::StatementInvalid, /row-level security policy/)
  ensure
    ActiveRecord::Base.connection.execute("ROLLBACK TO SAVEPOINT rls_rejection")
    ActiveRecord::Base.connection.execute("RELEASE SAVEPOINT rls_rejection")
  end

  def expect_db_rejection(pattern)
    ActiveRecord::Base.connection.execute("SAVEPOINT rls_rejection")
    expect { yield }.to raise_error(ActiveRecord::StatementInvalid, pattern)
  ensure
    ActiveRecord::Base.connection.execute("ROLLBACK TO SAVEPOINT rls_rejection")
    ActiveRecord::Base.connection.execute("RELEASE SAVEPOINT rls_rejection")
  end

  def insert_project_membership(project, user)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_memberships (project_id, user_id, role, created_at, updated_at)
      VALUES (#{project.id}, #{user.id}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_project_mcp_server(project, mcp_server)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_mcp_servers (project_id, mcp_server_definition_id, created_at, updated_at)
      VALUES (#{project.id}, #{mcp_server.id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_project_service_container(project, service_container)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_service_containers (project_id, service_container_id, created_at, updated_at)
      VALUES (#{project.id}, #{service_container.id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_orchestration_decision(project, strategy_version)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO orchestration_decisions (
        project_id,
        decision_type,
        actor,
        context,
        inputs,
        outputs,
        outcome_references,
        strategy_version_id,
        created_at,
        updated_at
      )
      VALUES (
        #{project.id},
        'select_agent',
        'rls',
        '{}'::jsonb,
        '{}'::jsonb,
        '{}'::jsonb,
        '[]'::jsonb,
        #{strategy_version.id},
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_issue_merge_subscription(issue, user)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO issue_merge_subscriptions (issue_id, user_id, subscription_type, created_at, updated_at)
      VALUES (#{issue.id}, #{user.id}, 'on_merge', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_account_membership(account, user)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO account_memberships (account_id, user_id, role, created_at, updated_at)
      VALUES (#{account.id}, #{user.id}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_pr_template(account, project_id: nil, user_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO pr_templates (account_id, project_id, user_id, name, body, created_at, updated_at)
      VALUES (
        #{account.id},
        #{sql_value(project_id)},
        #{sql_value(user_id)},
        #{quote("RLS PR Template #{SecureRandom.hex(4)}")},
        'Body',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_pre_commit_requirement(account, project_id: nil, user_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO pre_commit_requirements (account_id, project_id, user_id, name, command, created_at, updated_at)
      VALUES (
        #{account.id},
        #{sql_value(project_id)},
        #{sql_value(user_id)},
        #{quote("RLS Requirement #{SecureRandom.hex(4)}")},
        'bin/ci',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_quality_threshold(account, project)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO quality_thresholds (
        account_id,
        project_id,
        metric_type,
        goal_type,
        min_value,
        created_at,
        updated_at
      )
      VALUES (
        #{account.id},
        #{project.id},
        #{quote("rls_metric_#{SecureRandom.hex(4)}")},
        'issue',
        0.75,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_notification(account, user)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO notifications (account_id, user_id, source, severity, title, created_at, updated_at)
      VALUES (
        #{account.id},
        #{user.id},
        'rls',
        0,
        #{quote("RLS Notification #{SecureRandom.hex(4)}")},
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_github_token(account, user)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO github_tokens (account_id, created_by_id, name, token, created_at, updated_at)
      VALUES (
        #{account.id},
        #{user.id},
        #{quote("RLS Token #{SecureRandom.hex(4)}")},
        'ghp_test',
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_configuration_bundle(account, project_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO configuration_bundles (
        account_id,
        project_id,
        version,
        name,
        status,
        strategy_params,
        context,
        definition,
        created_at,
        updated_at
      )
      VALUES (
        #{account.id},
        #{sql_value(project_id)},
        999999,
        #{quote("RLS Bundle #{SecureRandom.hex(4)}")},
        'draft',
        '{}'::jsonb,
        '{}'::jsonb,
        '{"schema_version":1}'::jsonb,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_bundle_outcome(configuration_bundle, agent_run)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO bundle_outcomes (
        configuration_bundle_id,
        agent_run_id,
        success,
        metrics,
        created_at,
        updated_at
      )
      VALUES (
        #{configuration_bundle.id},
        #{agent_run.id},
        TRUE,
        '{}'::jsonb,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def expect_optional_account_reads_allowed(global_prompt, tenant_prompt, global_style_guide, tenant_style_guide)
    expect(Prompt.where(id: [ global_prompt.id, tenant_prompt.id ])).to contain_exactly(global_prompt, tenant_prompt)
    expect(StyleGuide.where(id: [ global_style_guide.id, tenant_style_guide.id ]))
      .to contain_exactly(global_style_guide, tenant_style_guide)
  end

  def expect_global_prompt_writes_blocked(prompt)
    expect(update_prompt_name(prompt, "Changed Global Prompt")).to eq(0)
    expect(delete_prompt(prompt)).to eq(0)
  end

  def expect_global_prompt_version_writes_blocked(prompt_version)
    expect(update_prompt_version_template(prompt_version, "Changed template")).to eq(0)
    expect(delete_prompt_version(prompt_version)).to eq(0)
  end

  def expect_global_style_guide_writes_blocked(style_guide)
    expect(update_style_guide_name(style_guide, "Changed Global Guide")).to eq(0)
    expect(delete_style_guide(style_guide)).to eq(0)
  end

  def update_prompt_name(prompt, name)
    ActiveRecord::Base.connection.update(<<~SQL.squish)
      UPDATE prompts
      SET name = #{quote(name)}
      WHERE id = #{prompt.id}
    SQL
  end

  def delete_prompt(prompt)
    ActiveRecord::Base.connection.delete("DELETE FROM prompts WHERE id = #{prompt.id}")
  end

  def update_prompt_version_template(prompt_version, template)
    ActiveRecord::Base.connection.update(<<~SQL.squish)
      UPDATE prompt_versions
      SET template = #{quote(template)}
      WHERE id = #{prompt_version.id}
    SQL
  end

  def delete_prompt_version(prompt_version)
    ActiveRecord::Base.connection.delete("DELETE FROM prompt_versions WHERE id = #{prompt_version.id}")
  end

  def update_style_guide_name(style_guide, name)
    ActiveRecord::Base.connection.update(<<~SQL.squish)
      UPDATE style_guides
      SET name = #{quote(name)}
      WHERE id = #{style_guide.id}
    SQL
  end

  def delete_style_guide(style_guide)
    ActiveRecord::Base.connection.delete("DELETE FROM style_guides WHERE id = #{style_guide.id}")
  end

  def insert_prompt(account_id:, project_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO prompts (account_id, project_id, slug, name, category, active, created_at, updated_at)
      VALUES (
        #{sql_value(account_id)},
        #{sql_value(project_id)},
        #{quote("rls.prompt-#{SecureRandom.hex(4)}")},
        'RLS Prompt',
        'coding',
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_prompt_version(prompt:)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO prompt_versions (prompt_id, version, template, variables, created_at)
      VALUES (
        #{prompt.id},
        #{SecureRandom.random_number(100_000) + 1},
        'RLS template',
        '{}',
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_style_guide(account_id:, project_id: nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO style_guides (account_id, project_id, name, raw_content, active, created_at, updated_at)
      VALUES (
        #{sql_value(account_id)},
        #{sql_value(project_id)},
        #{quote("RLS Style Guide #{SecureRandom.hex(4)}")},
        '# Style Guide',
        TRUE,
        CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP
      )
    SQL
  end

  def sql_value(value)
    value.nil? ? "NULL" : value
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
