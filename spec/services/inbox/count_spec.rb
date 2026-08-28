# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-010
RSpec.describe Inbox::Count do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true, owner: "acme", repo: "alpha")
  end

  describe ".call" do
    it "counts needs_input candidates on gated projects plus open plan reviews" do
      create(:issue, :needs_input, project: project)
      create(:issue, :needs_input, project: project)
      create(:decomposition_decision, project: project, workflow_id: "wf-1", decision_key: "wf-1:pending", decision_type: "planning_outcome", outcome: "plan_pending_review")

      expect(described_class.call(user: user)).to eq(3)
    end

    it "excludes closed issues and issues on non-gated projects" do
      create(:issue, :needs_input, project: project)
      create(:issue, :closed, :needs_input, project: project)
      other_project = create(:project, account: account, created_by: user, auto_pick_enabled: false, active: true, owner: "acme", repo: "beta")
      create(:issue, :needs_input, project: other_project)

      expect(described_class.call(user: user)).to eq(1)
    end

    it "returns zero when nothing is waiting" do
      expect(described_class.call(user: user)).to eq(0)
    end

    it "refreshes the cached count after the inbox cache version bumps" do
      # Created directly through the factory (bypassing
      # Orchestration::DecompositionDecisions::Log) so this mutation does not
      # itself trigger the auto-invalidation covered by the tests below —
      # isolating what's under test here to the TTL cache behavior.
      create(:decomposition_decision, project: project, workflow_id: "wf-1", decision_key: "wf-1:pending", decision_type: "planning_outcome", outcome: "plan_pending_review")
      first = described_class.call(user: user)

      create(:decomposition_decision, project: project, workflow_id: "wf-2", decision_key: "wf-2:pending", decision_type: "planning_outcome", outcome: "plan_pending_review")
      cached = described_class.call(user: user)
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      refreshed = described_class.call(user: user)

      expect(first).to eq(1)
      expect(cached).to eq(1)
      expect(refreshed).to eq(2)
    end

    it "bumps the cache automatically when an issue transitions into needs_input" do
      issue = create(:issue, project: project)
      first = described_class.call(user: user)

      issue.update!(paid_state: "needs_input")
      refreshed = described_class.call(user: user)

      expect(first).to eq(0)
      expect(refreshed).to eq(1)
    end

    it "bumps the cache automatically when a plan review decision is logged" do
      Strategies::SeedBaselineOrchestration.call
      first = described_class.call(user: user)

      Orchestration::DecompositionDecisions::Log.call(
        project_id: project.id,
        issue_id: create(:issue, project: project).id,
        decision_key: "wf-2:pending",
        workflow_name: "Workflows::PlanningWorkflow",
        workflow_id: "wf-2",
        decision_type: "planning_outcome",
        outcome: "plan_pending_review"
      )
      refreshed = described_class.call(user: user)

      expect(first).to eq(0)
      expect(refreshed).to eq(1)
    end
  end
end
