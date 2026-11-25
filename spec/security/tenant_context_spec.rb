# frozen_string_literal: true

require "rails_helper"
require "rake"
require Rails.root.join("db/migrate/20260421162139_enable_tenant_row_level_security")
require Rails.root.join("db/migrate/20260425113212_enable_rls_on_knowledge_usage_stats")
require Rails.root.join("db/migrate/20260425060000_enable_rls_on_notification_rule_states")
require Rails.root.join("db/migrate/20260426011810_enable_rls_on_llm_output_metrics")
require Rails.root.join("db/migrate/20260426231639_enable_rls_on_chat_tables")
require Rails.root.join("db/migrate/20260427225726_enable_rls_on_knowledge_recommendations")
require Rails.root.join("db/migrate/20260503093418_enable_rls_on_issue_merge_subscriptions")
require Rails.root.join("db/migrate/20260826082056_enable_rls_on_auto_merge_attempts")
require Rails.root.join("db/migrate/20260428140000_create_exception_incidents")
require Rails.root.join("db/migrate/20260512120010_add_logidze_to_exception_incidents")
require Rails.root.join("db/migrate/20260508120219_create_failure_classifications")
require Rails.root.join("db/migrate/20260507125050_create_decomposition_decisions")
require Rails.root.join("db/migrate/20260507164917_create_orchestration_decisions")
require Rails.root.join("db/migrate/20260507202027_add_strategy_version_to_orchestration_decisions")
require Rails.root.join("db/migrate/20260507211918_enable_rls_on_strategies_and_strategy_versions")
require Rails.root.join("db/migrate/20260507224416_enable_rls_on_strategy_experiment_tables")
require Rails.root.join("db/migrate/20260508064240_tighten_orchestration_decisions_strategy_version_tenant_check")
require Rails.root.join("db/migrate/20260509083302_ensure_strategy_version_id_on_orchestration_decisions")
require Rails.root.join("db/migrate/20260511040425_fix_strategies_rls_infinite_recursion")
require Rails.root.join("db/migrate/20260730190357_make_projects_github_token_optional_in_rls")
require Rails.root.join("db/migrate/20261029221250_create_inbox_history_events")
require Rails.root.join("db/migrate/20261105195000_create_bounded_delegated_actions")
require Rails.root.join("db/migrate/20261107082941_create_trusted_measurement_attempts")
require Rails.root.join("db/migrate/20261107200000_create_project_delegation_postures")
require Rails.root.join("db/migrate/20261116080000_create_staged_closeout_adoption")
require Rails.root.join("db/migrate/20261117100000_create_project_delegation_intent_checkpoints")
require Rails.root.join("db/migrate/20261123000000_secure_conflict_repair_scope_evidences")
require Rails.root.join("db/migrate/20261124133739_enable_tenant_rls_on_shared_delivery_evidence_associations")

RSpec.describe TenantContext, :tenant_isolation do # @spec POSTGRESQL-PERSISTENCE-001
  around do |example|
    skip "requires CREATE ROLE privilege for RLS policy checks" unless can_manage_roles?

    # @spec POSTGRESQL-PERSISTENCE-012 — preserve newer canonical policy groups
    # instead of leaving the historical fixture's policy reconstruction behind.
    ActiveRecord::Base.transaction(requires_new: true) do
      install_tenant_policies
      example.run
      raise ActiveRecord::Rollback
    end
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

  it "exposes projects without a github token to their own account only" do
    tokenless_a = described_class.with_system_access { create(:project, :with_github_installation, account: account_a) }
    described_class.with_system_access { create(:project, :with_github_installation, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) { expect(Project.all).to contain_exactly(tokenless_a) }
      described_class.with(account_b) { expect(Project.all).not_to include(tokenless_a) }
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

  # @spec AUTO-MERGE-011
  it "isolates conflict-repair scope evidence by producer account" do
    evidence_a = described_class.with_system_access { create_conflict_scope_evidence(account_a) }
    described_class.with_system_access { create_conflict_scope_evidence(account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect(ConflictRepairScopeEvidence.all).to contain_exactly(evidence_a)
      end
    end
  end

  # @spec AUTO-MERGE-011 POSTGRESQL-PERSISTENCE-006
  it "rejects conflict-repair scope evidence with cross-tenant producer references" do
    evidence_a = described_class.with_system_access { create_conflict_scope_evidence(account_a) }
    project_b, issue_b, user_b = described_class.with_system_access do
      project = create(:project, account: account_b)
      [ project, create(:issue, :pull_request, project:), create(:user, account: account_b) ]
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect_rls_rejection do
          insert_conflict_scope_evidence(account_a, evidence_a.agent_run, project_b, evidence_a.issue)
        end
        expect_rls_rejection do
          insert_conflict_scope_evidence(account_a, evidence_a.agent_run, evidence_a.project, issue_b)
        end
        expect_rls_rejection do
          insert_conflict_scope_evidence(account_a, evidence_a.agent_run, evidence_a.project, evidence_a.issue, user_b)
        end
      end
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-001 PARTIAL-CLOSEOUT-063
  it "forces tenant isolation for shared delivery evidence reads and writes" do
    evidence_b = described_class.with_system_access { create_shared_delivery_evidence(account_b) }
    evidence_a = described_class.with_system_access { create_shared_delivery_evidence(account_a) }

    flags = ActiveRecord::Base.connection.select_one(<<~SQL.squish)
      SELECT relrowsecurity, relforcerowsecurity
      FROM pg_class
      WHERE oid = 'shared_delivery_evidence_associations'::regclass
    SQL
    expect(flags).to include("relrowsecurity" => true, "relforcerowsecurity" => true)

    as_restricted_role do
      described_class.with(account_a) do
        expect(SharedDeliveryEvidenceAssociation.all).to contain_exactly(evidence_a)
        expect_rls_rejection { insert_shared_delivery_evidence(evidence_b, account_id: account_a.id) }
      end
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-001 POSTGRESQL-PERSISTENCE-006 BOUNDED-PHASE-AUTHORIZATION-010
  it "isolates bounded delegated actions and rejects cross-tenant scope references" do
    action_a = described_class.with_system_access do
      project = create(:project, account: account_a)
      create(:bounded_delegated_action, account: account_a, project:, issue: create(:issue, project:))
    end
    project_b, issue_b, user_b = described_class.with_system_access do
      project = create(:project, account: account_b)
      issue = create(:issue, project:)
      create(:bounded_delegated_action, account: account_b, project:, issue:)
      [ project, issue, create(:user, account: account_b) ]
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect(BoundedDelegatedAction.all).to contain_exactly(action_a)
        expect_rls_rejection { insert_bounded_delegated_action(account_a, project_b, issue_b) }
        expect_rls_rejection { insert_bounded_delegated_action(account_a, action_a.project, issue_b) }
        expect_rls_rejection { insert_bounded_delegated_action(account_a, action_a.project, action_a.issue, user_b) }
      end
      described_class.clear!
      expect(BoundedDelegatedAction.all).to be_empty
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-001 PROJECT-DELEGATION-001
  it "isolates delegation postures and rejects cross-tenant scope references" do
    posture_a = described_class.with_system_access do
      project = create(:project, account: account_a)
      create(:project_delegation_posture, account: account_a, project:)
    end
    project_b = described_class.with_system_access do
      project = create(:project, account: account_b)
      create(:project_delegation_posture, account: account_b, project:)
      project
    end
    user_b = described_class.with_system_access { create(:user, account: account_b) }

    as_restricted_role do
      described_class.with(account_a) do
        expect(ProjectDelegationPosture.all).to contain_exactly(posture_a)
        expect_rls_rejection { insert_project_delegation_posture(account_a, project_b) }
        expect_rls_rejection { insert_project_delegation_posture(account_a, posture_a.project, user_b) }
      end
      described_class.clear!
      expect(ProjectDelegationPosture.all).to be_empty
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-001 PROJECT-DELEGATION-002
  it "isolates intent checkpoints and rejects cross-tenant settlement references" do
    checkpoint_a, settler_a = described_class.with_system_access do
      intent = create(:feature_intent, project: create(:project, account: account_a))
      [ create(:project_delegation_intent_checkpoint, feature_intent: intent), create(:user, account: account_a) ]
    end
    checkpoint_b, settler_b = described_class.with_system_access do
      intent = create(:feature_intent, project: create(:project, account: account_b))
      [ create(:project_delegation_intent_checkpoint, feature_intent: intent), create(:user, account: account_b) ]
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect(ProjectDelegation::IntentCheckpoint.all).to contain_exactly(checkpoint_a)
        insert_project_delegation_intent_settlement(checkpoint_a, settler_a)
        expect(ProjectDelegation::IntentSettlement.where(intent_checkpoint_id: checkpoint_a.id).count).to eq(1)
        expect_rls_rejection { insert_project_delegation_intent_settlement(checkpoint_a, settler_b) }
        expect_rls_rejection { insert_project_delegation_intent_settlement(checkpoint_b, settler_a) }
      end
      described_class.clear!
      expect(ProjectDelegation::IntentSettlement.all).to be_empty
    end
  end

  # @spec TRUSTED-MEASUREMENTS-001
  it "isolates trusted measurement attempts and rejects cross-tenant scope references" do
    attempt_a = described_class.with_system_access do
      project = create(:project, account: account_a)
      create(:trusted_measurement_attempt, account: account_a, project:, issue: create(:issue, project:))
    end
    project_b, issue_b = described_class.with_system_access do
      project = create(:project, account: account_b)
      issue = create(:issue, project:)
      create(:trusted_measurement_attempt, account: account_b, project:, issue:)
      [ project, issue ]
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect(TrustedMeasurementAttempt.all).to contain_exactly(attempt_a)
        expect_rls_rejection { insert_trusted_measurement_attempt(account_a, project_b, issue_b) }
        expect_rls_rejection { insert_trusted_measurement_attempt(account_a, attempt_a.project, issue_b) }
      end
      described_class.clear!
      expect(TrustedMeasurementAttempt.all).to be_empty
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 STAGED-CLOSEOUT-ADOPTION-003
  it "rejects cross-tenant staged closeout enrollment references" do
    project_a, reviewer_a, enrollment_a = described_class.with_system_access do
      project = create(:project, account: account_a)
      reviewer = create(:user, account: account_a)
      enrollment = StagedCloseoutEnrollment.create!(account: account_a, project:, reviewed_by: reviewer)
      [ project, reviewer, enrollment ]
    end
    project_b, reviewer_b = described_class.with_system_access do
      [ create(:project, account: account_b), create(:user, account: account_b) ]
    end

    as_restricted_role do
      described_class.with(account_a) do
        expect_rls_rejection { insert_staged_closeout_enrollment(account_a, project_b, reviewer_a) }
        expect_rls_rejection { insert_staged_closeout_enrollment(account_a, project_a, reviewer_b) }
        expect_rls_rejection { update_staged_closeout_enrollment(enrollment_a, reviewed_by: reviewer_b) }
      end
    end
  end

  # @spec POSTGRESQL-PERSISTENCE-006 STAGED-CLOSEOUT-ADOPTION-003
  it "rejects cross-tenant staged closeout mapping references on inserts and updates" do
    scope_a = described_class.with_system_access { staged_closeout_scope(account_a) }
    scope_b = described_class.with_system_access { staged_closeout_scope(account_b) }
    mapping_a = described_class.with_system_access { create_staged_closeout_mapping(scope_a) }

    as_restricted_role do
      described_class.with(account_a) do
        %i[project issue enrollment reviewed_by invalidated_by].each do |reference|
          expect_rls_rejection { insert_staged_closeout_mapping(scope_a.merge(reference => scope_b.fetch(reference))) }
        end
        expect_rls_rejection { update_staged_closeout_mapping(mapping_a, issue: scope_b.fetch(:issue)) }
      end
    end
  end

  # @spec TRUSTED-MEASUREMENTS-003
  it "collects an operator measurement from a restricted process without tenant context" do
    project = described_class.with_system_access { create(:project, account: account_a) }
    described_class.with_system_access { create(:issue, project:, github_number: 4812) }
    as_restricted_role do
      with_trusted_measurement_task(project) do |task|
        described_class.with(nil) do
          expect { task.invoke }.to output(/status:\s+succeeded/).to_stdout
          expect(described_class.bypass_enabled?).to be(false)
        end
      end
    end
    described_class.with(account_a) do
      expect(TrustedMeasurementAttempt.find_by!(project:).status).to eq("succeeded")
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

  it "does not return tenant rows without tenant context" do # @spec POSTGRESQL-PERSISTENCE-001
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

  # @spec POSTGRESQL-PERSISTENCE-002 OPERATOR-INBOX-022
  it "rejects Inbox history rows that attach another account's project" do
    account = described_class.with_system_access { account_a }
    project_b = described_class.with_system_access { create(:project, account: account_b) }

    as_restricted_role do
      described_class.with(account) do
        expect_rls_rejection { insert_inbox_history_event(account, project_b) }
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

  def with_trusted_measurement_task(project)
    keys = %w[PROJECT_ID TARGET_REVISION CHECK_KEY EXTERNAL_ISSUE_NUMBER CRITERION_KEY]
    previous = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    ENV["PROJECT_ID"] = project.id.to_s
    ENV["TARGET_REVISION"] = "reviewed-revision"
    allow(TrustedMeasurements::DeploymentSignal).to receive(:current).and_return("reviewed-revision")
    Rails.application.load_tasks unless Rake::Task.task_defined?("trusted_measurements:run_check")
    task = Rake::Task["trusted_measurements:run_check"]
    task.reenable
    yield task
  ensure
    keys&.each { |key| ENV.delete(key) }
    previous&.each { |key, value| ENV[key] = value }
  end

  def install_tenant_policies
    ActiveRecord::Migration.suppress_messages do
      TightenOrchestrationDecisionsStrategyVersionTenantCheck.new.down if orchestration_decisions_have_strategy_version_reference?
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
      EnableRlsOnAutoMergeAttempts.new.down if auto_merge_attempts_have_rls?
      CreateFailureClassifications.new.down if failure_classifications_table_exists?
      CreateInboxHistoryEvents.new.down if inbox_history_events_table_exists?
      CreateProjectDelegationIntentCheckpoints.new.down if intent_checkpoint_tables_exist?
      EnableTenantRowLevelSecurity.new.down
      EnableTenantRowLevelSecurity.new.up
      CreateBoundedDelegatedActions.new.enable_tenant_rls
      CreateTrustedMeasurementAttempts.new.enable_tenant_rls
      CreateProjectDelegationPostures.new.enable_tenant_rls
      CreateStagedCloseoutAdoption.new.disable_tenant_rls
      CreateStagedCloseoutAdoption.new.enable_tenant_rls
      EnableTenantRlsOnSharedDeliveryEvidenceAssociations.new.down if shared_delivery_evidence_has_rls?
      EnableTenantRlsOnSharedDeliveryEvidenceAssociations.new.up
      EnableRlsOnNotificationRuleStates.new.up
      EnableRlsOnKnowledgeUsageStats.new.up unless knowledge_usage_stats_has_rls?
      EnableRlsOnLlmOutputMetrics.new.up unless llm_output_metrics_has_rls?
      EnableRlsOnChatTables.new.up unless chat_tables_have_rls?
      EnableRlsOnKnowledgeRecommendations.new.up unless knowledge_recommendations_has_rls?
      EnableRlsOnIssueMergeSubscriptions.new.up unless issue_merge_subscriptions_has_rls?
      EnableRlsOnAutoMergeAttempts.new.up unless auto_merge_attempts_have_rls?
      CreateExceptionIncidents.new.up unless exception_incidents_table_exists?
      restore_exception_incidents_logidze!
      CreateFailureClassifications.new.up unless failure_classifications_table_exists?
      CreateInboxHistoryEvents.new.up unless inbox_history_events_table_exists?
      CreateProjectDelegationIntentCheckpoints.new.up unless intent_checkpoint_tables_exist?
      SecureConflictRepairScopeEvidences.new.enable_tenant_rls
      CreateOrchestrationDecisions.new.up unless orchestration_decisions_table_exists?
      AddStrategyVersionToOrchestrationDecisions.new.migrate(:up) unless orchestration_decisions_have_strategy_version_reference?
      ensure_strategy_version_id_on_orchestration_decisions unless orchestration_decisions_have_strategy_version_reference?
      TightenOrchestrationDecisionsStrategyVersionTenantCheck.new.up if orchestration_decisions_have_strategy_version_reference?
      EnableRlsOnStrategyExperimentTables.new.up unless strategy_experiment_tables_have_rls?
      EnableRlsOnStrategiesAndStrategyVersions.new.up unless strategies_have_rls?
      FixStrategiesRlsInfiniteRecursion.new.up
      MakeProjectsGithubTokenOptionalInRls.new.up
    end
    OrchestrationDecision.reset_column_information
    ActiveRecord::Base.connection.execute("RESET ROLE")
    cleanup_restricted_role
    ActiveRecord::Base.connection.execute("CREATE ROLE paid_rls_spec NOLOGIN")
    ActiveRecord::Base.connection.execute("GRANT USAGE ON SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO paid_rls_spec")
    ActiveRecord::Base.connection.execute("GRANT paid_rls_spec TO current_user")
  end

  def knowledge_recommendations_has_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'knowledge_recommendations' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def shared_delivery_evidence_has_rls?
    ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
      SELECT COUNT(*) FROM pg_policies
      WHERE tablename = 'shared_delivery_evidence_associations'
        AND policyname = 'tenant_isolation'
    SQL
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

  def auto_merge_attempts_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'auto_merge_attempts' AND policyname = 'tenant_isolation'"
    ).to_i.positive?
  end

  def conflict_repair_scope_evidences_have_rls?
    ActiveRecord::Base.connection.select_value(
      "SELECT COUNT(*) FROM pg_policies WHERE tablename = 'conflict_repair_scope_evidences' AND policyname = 'tenant_isolation'"
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

  def restore_exception_incidents_logidze!
    return unless exception_incidents_table_exists?
    return if ActiveRecord::Base.connection.column_exists?(:exception_incidents, :log_data)

    AddLogidzeToExceptionIncidents.new.migrate(:up)
  end

  def failure_classifications_table_exists?
    ActiveRecord::Base.connection.table_exists?(:failure_classifications)
  end

  def inbox_history_events_table_exists?
    ActiveRecord::Base.connection.table_exists?(:inbox_history_events)
  end

  def intent_checkpoint_tables_exist?
    ActiveRecord::Base.connection.table_exists?(:project_delegation_intent_checkpoints)
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

  def insert_shared_delivery_evidence(evidence, account_id: evidence.account_id)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO shared_delivery_evidence_associations (
        account_id, project_id, issue_id, pull_request_id, authorized_by_id,
        pull_request_url, revision, created_at, updated_at
      ) VALUES (
        #{account_id}, #{evidence.project_id}, #{evidence.issue_id},
        #{evidence.pull_request_id}, #{evidence.authorized_by_id},
        #{ActiveRecord::Base.connection.quote(evidence.pull_request_url)},
        #{ActiveRecord::Base.connection.quote(evidence.revision)},
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def create_shared_delivery_evidence(account)
    actor = create(:user, :member, account:)
    project = create(:project, account:, owner: "tenant-#{account.id}", repo: "repo")
    issue = create(:issue, project:)
    pull_request = create(:issue, :pull_request, project:, pr_review_phase: "merged",
      github_state: "closed", github_html_url: "#{project.github_url}/pull/99",
      github_number: 99, merged_commit_sha: "a" * 40)
    Issues::AssociateSharedDeliveryEvidence.call(issue:, pull_request:, actor:)
  end

  def insert_inbox_history_event(account, project)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO inbox_history_events (
        account_id, project_id, subject_key, event_key, occurred_at,
        actor_label, source, result, metadata, created_at, updated_at
      ) VALUES (
        #{account.id}, #{project.id}, 'issue:#{project.id}:1', 'test', CURRENT_TIMESTAMP,
        'Paid', 'paid', 'completed', '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_bounded_delegated_action(account, project, issue, created_by = nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO bounded_delegated_actions (
        account_id, project_id, issue_id, created_by_id, action, status,
        evidence, expires_at, created_at, updated_at
      ) VALUES (
        #{account.id}, #{project.id}, #{issue.id}, #{sql_value(created_by&.id)}, 'review', 'active',
        '{"intent_digest":"rls","acceptance_refs":["AC-1"]}'::jsonb,
        CURRENT_TIMESTAMP + INTERVAL '1 hour', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_project_delegation_posture(account, project, selected_by = nil)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_delegation_postures (
        account_id, project_id, selected_by_id, level, revision, enabled_action_classes,
        policy_signature, created_at, updated_at
      ) VALUES (
        #{account.id}, #{project.id}, #{sql_value(selected_by&.id)}, 'bounded_delivery', 1,
        '["technical_stop_recovery"]'::jsonb, 'sig', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_project_delegation_intent_settlement(checkpoint, settled_by)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO project_delegation_intent_settlements (
        intent_checkpoint_id, settled_by_id, disposition, answers,
        design_revision, acceptance_revision, settled_at, created_at, updated_at
      ) VALUES (
        #{checkpoint.id}, #{settled_by.id}, 'settled', '{}'::jsonb,
        'design-1', 'acceptance-1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_trusted_measurement_attempt(account, project, issue)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO trusted_measurement_attempts (
        account_id, project_id, issue_id, external_issue_number, criterion_key, check_key,
        check_version, status, result, created_at, updated_at
      ) VALUES (
        #{account.id}, #{project.id}, #{issue.id}, #{issue.github_number},
        'closed_planning_hold_notifications_cleared', 'agent_planning_hold_reconciliation_closed_count',
        1, 'pending', '{}'::jsonb, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def insert_staged_closeout_enrollment(account, project, reviewed_by)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO staged_closeout_enrollments (
        account_id, project_id, reviewed_by_id, revision, enabled, created_at, updated_at
      ) VALUES (
        #{account.id}, #{project.id}, #{reviewed_by.id}, 1, FALSE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def update_staged_closeout_enrollment(enrollment, reviewed_by:)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      UPDATE staged_closeout_enrollments
      SET reviewed_by_id = #{reviewed_by.id}
      WHERE id = #{enrollment.id}
    SQL
  end

  def staged_closeout_scope(account)
    project = create(:project, account:)
    {
      account:, project:, issue: create(:issue, project:),
      enrollment: StagedCloseoutEnrollment.create!(account:, project:),
      reviewed_by: create(:user, account:), invalidated_by: create(:user, account:)
    }
  end

  def create_staged_closeout_mapping(scope)
    StagedCloseoutMapping.create!(staged_closeout_mapping_attributes(scope))
  end

  def insert_staged_closeout_mapping(scope)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO staged_closeout_mappings (
        account_id, project_id, issue_id, staged_closeout_enrollment_id,
        reviewed_by_id, invalidated_by_id, criterion_key, criterion_digest,
        stage, phase, target_shape, execution_path, target_key, target_version,
        target_digest, freshness_seconds, retry_policy, revision, reviewed_at,
        created_at, updated_at
      ) VALUES (
        #{scope.fetch(:account).id}, #{scope.fetch(:project).id}, #{scope.fetch(:issue).id},
        #{scope.fetch(:enrollment).id}, #{scope.fetch(:reviewed_by).id}, #{scope.fetch(:invalidated_by).id},
        #{quote("AC-#{SecureRandom.hex(4)}")}, 'criterion-digest', 'pre_merge', 'implementation',
        'checkout', 'technical_prerequisite', 'bin/ci', '1', 'target-digest', 300,
        '{}'::jsonb, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def update_staged_closeout_mapping(mapping, issue:)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      UPDATE staged_closeout_mappings SET issue_id = #{issue.id} WHERE id = #{mapping.id}
    SQL
  end

  def staged_closeout_mapping_attributes(scope)
    scope.slice(:account, :project, :issue, :reviewed_by, :invalidated_by).merge(
      staged_closeout_enrollment: scope.fetch(:enrollment), criterion_key: "AC-1",
      criterion_digest: "criterion-digest", stage: "pre_merge", phase: "implementation",
      target_shape: "checkout", execution_path: "technical_prerequisite", target_key: "bin/ci",
      target_version: "1", target_digest: "target-digest", freshness_seconds: 300,
      retry_policy: {}, revision: 1, reviewed_at: Time.current
    )
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

  def create_conflict_scope_evidence(account)
    project = create(:project, account:)
    issue = create(:issue, :pull_request, project:)
    run = create(:agent_run, project:, issue:, external_metadata: { "pre_run_head_sha" => "pre" })
    ConflictRepairScopeEvidence.create!(agent_run: run, account:, project:, issue:, pre_run_sha: "pre",
      integration_base_sha: "base", result_sha: "head", provider_head_sha: "head",
      status: "approved", explanation: "bounded", base_imported_paths: [], repair_authored_paths: [])
  end

  def insert_conflict_scope_evidence(account, agent_run, project, issue, requested_by = nil)
    suffix = SecureRandom.hex(4)
    ActiveRecord::Base.connection.execute(<<~SQL.squish)
      INSERT INTO conflict_repair_scope_evidences (
        account_id, agent_run_id, project_id, issue_id, requested_by_id, pre_run_sha,
        integration_base_sha, result_sha, provider_head_sha, status, explanation,
        base_imported_paths, repair_authored_paths, created_at, updated_at
      ) VALUES (
        #{account.id}, #{agent_run.id}, #{project.id}, #{issue.id}, #{sql_value(requested_by&.id)},
        #{quote("pre-#{suffix}")}, #{quote("base-#{suffix}")}, #{quote("result-#{suffix}")},
        #{quote("head-#{suffix}")}, 'approved', 'bounded', '[]'::jsonb, '[]'::jsonb,
        CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end

  def quote(value)
    ActiveRecord::Base.connection.quote(value)
  end
end
