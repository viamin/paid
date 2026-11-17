# frozen_string_literal: true

require "rails_helper"

# RDR-077 Rollout Guard: rollback protection. A project with an active
# continuation grant can never silently revert to legacy interpretation, and
# affected queued work is reconciled before a rollback takes effect.
#
# @spec AUTOMATION-PHASES-014
RSpec.describe Automation::Phases::RollbackProtection do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:, auto_pick_enabled: true) }

  before do
    FeatureFlags.flipper.features.each(&:remove)
    FeatureFlags.enable!(:automation_phases, project:)
  end

  def configure_phases(phases)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  def queued_run(issue:, goal: "create_pr", **attrs)
    create(:agent_run, :queued, project:, issue:, goal:, trigger_type: "automatic", auto_pick: true, **attrs)
  end

  describe "project-scoped rollback" do
    it "refuses while a continuation grant is active, preserving all state" do
      issue = create(:issue, project:, github_state: "open")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      configure_phases("coding" => false, "merge" => false)
      settings_before = project.reload[Automation::PhaseSettings::SETTINGS_KEY]

      expect {
        FeatureFlags.disable!(:automation_phases, project:)
      }.to raise_error(FeatureFlags::RollbackBlockedError) do |error|
        expect(error.message).to include(project.full_name)
        expect(error.message).to include("active continuation grant")
        expect(error.message).to include("revoke")
        expect(error.details[:flag]).to eq(:automation_phases)
        expect(error.details[:projects]).to include(
          hash_including(id: project.id, full_name: project.full_name, active_grants: 1)
        )
      end

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
      expect(grant.reload).to be_active
      expect(project.reload[Automation::PhaseSettings::SETTINGS_KEY]).to eq(settings_before)
    end

    it "reconciles affected queued work and permits rollback after the grant is revoked" do
      issue = create(:issue, project:, github_state: "open")
      configure_phases("coding" => false, "merge" => false)
      run = queued_run(issue:)
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.revoke!

      expect { FeatureFlags.disable!(:automation_phases, project:) }.not_to raise_error

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
      expect(run.reload.status).to eq("cancelled")
      expect(run.reload.error_message).to include("Authorization for create_pr was withdrawn")
      expect(grant.reload).to be_revoked
    end

    it "reconciles affected queued work after the grant completes at its endpoint" do
      issue = create(:issue, project:, github_state: "open")
      configure_phases("coding" => false, "merge" => false)
      run = queued_run(issue:)
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.complete!

      FeatureFlags.disable!(:automation_phases, project:)

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
      expect(run.reload.status).to eq("cancelled")
      expect(grant.reload).to be_completed
    end

    it "permits rollback with no grants at all" do
      FeatureFlags.disable!(:automation_phases, project:)

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
    end

    it "preserves independently authorized queued work across a safe rollback" do
      issue = create(:issue, project:, github_state: "open")
      configure_phases("coding" => true, "merge" => true)
      run = queued_run(issue:)
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.complete!

      FeatureFlags.disable!(:automation_phases, project:)

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
      expect(run.reload.status).to eq("queued")
    end

    it "refuses with a pending-reconciliation reason when an affected queued run cannot be reconciled" do
      issue = create(:issue, project:, github_state: "open")
      configure_phases("coding" => false, "merge" => false)
      # A claimed run keeps its workflow id, so the dequeue recheck cannot
      # cancel it and the queue still owes its standing to the grant.
      run = queued_run(issue:, temporal_workflow_id: "workflow-in-flight")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.revoke!

      expect {
        FeatureFlags.disable!(:automation_phases, project:)
      }.to raise_error(FeatureFlags::RollbackBlockedError) do |error|
        expect(error.message).to include("queued")
        expect(error.message).to include("reconcil")
        expect(error.details[:pending_runs]).to include(
          hash_including(project_id: project.id, agent_run_ids: [ run.id ])
        )
      end

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
      expect(run.reload.status).to eq("queued")
    end

    it "ignores queued work outside continuation-grant chains" do
      chained = create(:issue, project:, github_state: "open")
      unrelated = create(:issue, project:, github_state: "open")
      configure_phases("coding" => false, "merge" => false)
      chained_run = queued_run(issue: chained)
      unrelated_run = queued_run(issue: unrelated)
      grant = create(:work_item_continuation_grant, project:, issue: chained, start_phase: "coding", endpoint: "merge")
      grant.revoke!

      FeatureFlags.disable!(:automation_phases, project:)

      expect(chained_run.reload.status).to eq("cancelled")
      expect(unrelated_run.reload.status).to eq("queued")
    end

    it "does not guard a project whose rollout is already off" do
      other = create(:project, account:)

      expect { FeatureFlags.disable!(:automation_phases, project: other) }.not_to raise_error
    end

    it "does not guard other feature flags" do
      FeatureFlags.enable!(:question_exploration, project:)

      expect { FeatureFlags.disable!(:question_exploration, project:) }.not_to raise_error
      expect(FeatureFlags.enabled?(:question_exploration, project:)).to be(false)
    end
  end

  describe "global rollback" do
    it "refuses when any enabled project with grants would lose the phase model" do
      issue = create(:issue, project:, github_state: "open")
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      expect {
        FeatureFlags.disable!(:automation_phases)
      }.to raise_error(FeatureFlags::RollbackBlockedError, /#{project.full_name}/)

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
    end

    it "permits a global disable when grants exist only in never-enabled projects" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      issue = create(:issue, project: other_project, github_state: "open")
      create(:work_item_continuation_grant, project: other_project, issue:, start_phase: "coding", endpoint: "merge")

      expect { FeatureFlags.disable!(:automation_phases) }.not_to raise_error
      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
      expect(FeatureFlags.enabled?(:automation_phases, project: other_project)).to be(false)
    end

    it "does not block a global disable for a project a tenant override keeps enabled" do
      create(:tenant_setting, account:, features: { "automation_phases" => true })
      issue = create(:issue, project:, github_state: "open")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      expect { FeatureFlags.disable!(:automation_phases) }.not_to raise_error

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
      expect(grant.reload).to be_active
    end
  end

  describe "tenant-settings rollback" do
    it "refuses a tenant features flip that would disable a granted project and changes nothing" do
      issue = create(:issue, project:, github_state: "open")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      features_before = account.tenant_setting&.features

      expect {
        described_class.protect_tenant_features(account:, features: { "automation_phases" => "false" }) do
          raise "guarded mutation must not run"
        end
      }.to raise_error(FeatureFlags::RollbackBlockedError, /#{project.full_name}/)

      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(true)
      expect(grant.reload).to be_active
      expect(account.tenant_setting&.reload&.features).to eq(features_before)
    end

    it "reconciles and permits the tenant flip once grants are inactive" do
      setting = create(:tenant_setting, account:, features: {})
      issue = create(:issue, project:, github_state: "open")
      configure_phases("coding" => false, "merge" => false)
      run = queued_run(issue:)
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.revoke!
      applied = described_class.protect_tenant_features(account:, features: { "automation_phases" => false }) do
        setting.update!(features: { "automation_phases" => false })
        :applied
      end

      expect(applied).to eq(:applied)
      expect(FeatureFlags.enabled?(:automation_phases, project:)).to be(false)
      expect(run.reload.status).to eq("cancelled")
    end

    it "ignores projects of other tenants" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)
      FeatureFlags.enable!(:automation_phases, project: other_project)
      issue = create(:issue, project: other_project, github_state: "open")
      create(:work_item_continuation_grant, project: other_project, issue:, start_phase: "coding", endpoint: "merge")

      applied = described_class.protect_tenant_features(account:, features: { "automation_phases" => false }) do
        :applied
      end

      expect(applied).to eq(:applied)
      expect(FeatureFlags.enabled?(:automation_phases, project: other_project)).to be(true)
    end

    it "yields when the tenant features do not disable the phase model" do
      applied = described_class.protect_tenant_features(account:, features: { "automation_phases" => "1" }) do
        :applied
      end

      expect(applied).to eq(:applied)
    end
  end

  describe "locking" do
    it "guards the mutation behind the per-project advisory lock" do
      issue = create(:issue, project:, github_state: "open")
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.revoke!

      queries = capture_queries do
        FeatureFlags.disable!(:automation_phases, project:)
      end

      expect(queries.join).to match(/pg_advisory_xact_lock.*#{project.id}/)
    end

    it "shares the lock namespace with grant creation" do
      issue = create(:issue, project:, github_state: "open")
      queries = capture_queries do
        described_class.with_project_lock(project) { project.work_item_continuation_grants.active.to_a }
      end

      expect(queries.join).to include("pg_advisory_xact_lock")
    end
  end
end
