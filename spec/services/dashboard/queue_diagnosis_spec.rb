# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-DIAG-001 @spec QUEUE-DIAG-002 @spec QUEUE-DIAG-003
# @spec QUEUE-DIAG-009 @spec QUEUE-DIAG-011 @spec QUEUE-DIAG-012
RSpec.describe Dashboard::QueueDiagnosis do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true,
      last_issue_sync_at: Time.current)
  end

  before { Rails.cache.clear }

  describe ".call" do
    # @spec QUEUE-DIAG-001
    it "reports runnable work that was never queued as runnable_not_seeded" do
      create(:issue, project: project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.state).to eq(:runnable_not_seeded)
      expect(result.counts.eligible).to eq(1)
      expect(result.counts.queued).to eq(0)
      expect(result.counts.running).to eq(0)
    end

    # @spec QUEUE-DIAG-001
    it "reports healthy active work with no waiting backlog" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :running, :automatic, project: project, issue: issue, goal: "create_pr", auto_pick: true)

      result = described_class.call(user: user)

      expect(result.state).to eq(:healthy)
      expect(result.counts.running).to eq(1)
      expect(result.counts.eligible).to eq(0)
    end

    # @spec QUEUE-DIAG-001
    it "reports an empty queue with nothing open as healthy rather than a failure" do
      result = described_class.call(user: user)

      expect(result.state).to eq(:healthy)
      expect(result.counts.eligible).to eq(0)
      expect(result.counts.blocked).to eq(0)
      expect(result.counts.paused).to eq(0)
      expect(result.failed?).to be(false)
    end

    # @spec QUEUE-DIAG-002
    it "keeps eligible candidates apart from queued and running work" do
      queued_issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :queued, :automatic, project: project, issue: queued_issue, goal: "create_pr", auto_pick: true)

      result = described_class.call(user: user)

      expect(result.counts.queued).to eq(1)
      expect(result.counts.eligible).to eq(0)
    end

    # @spec QUEUE-DIAG-003
    it "reports a genuine dependency chain with the owning prerequisite work" do
      blocker = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "tracking" ])
      dependent = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      result = described_class.call(user: user)

      expect(result.state).to eq(:blocked)
      detail = result.blockers.detect { |candidate| candidate.issue.id == dependent.id }
      expect(detail).to be_present
      expect(detail.blockers.map(&:code)).to include(:unmet_prerequisites)
      expect(detail.owners).to include("##{blocker.github_number}")
      expect(detail.blockers.map(&:recovery)).to all(be_present)
    end

    # @spec QUEUE-DIAG-003
    it "reports every simultaneous blocker instead of only the first one" do
      create(:issue, project: project, github_state: "open", paid_state: "manual_review",
        labels: [ "tracking" ], manual_review_reason: "Round limit reached.")

      result = described_class.call(user: user)

      detail = result.blockers.first
      expect(detail.blockers.map(&:code)).to include(:human_decision, :skip_label)
    end

    # @spec QUEUE-DIAG-003
    it "reports the last successful stall assessment for a blocked issue" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "tracking" ])
      QueueStallAssessment.create!(
        account: account, issue: issue, reason_code: "stale_planning_hold",
        state_digest: "digest", outcome: "blocked", assessed_at: 2.hours.ago
      )

      result = described_class.call(user: user)

      detail = result.blockers.detect { |candidate| candidate.issue.id == issue.id }
      expect(detail.assessment).to be_present
      expect(detail.assessment.outcome).to eq("blocked")
    end

    # @spec QUEUE-DIAG-001
    it "reports a paused project as paused rather than as a failure" do
      project.update!(paused: true)
      create(:issue, project: project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.state).to eq(:paused)
      expect(result.counts.paused).to eq(1)
      expect(result.counts.eligible).to eq(0)
    end

    # @spec QUEUE-DIAG-001
    it "reports a scheduler-paused account as paused" do
      account.update!(scheduler_paused_at: Time.current)
      create(:issue, project: project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.state).to eq(:paused)
    end

    # @spec QUEUE-DIAG-009
    it "reports unknown coverage instead of claiming there is no work" do
      project.update!(last_issue_sync_at: 2.days.ago)

      result = described_class.call(user: user)

      expect(result.state).to eq(:unknown)
      expect(result.projects.first.coverage).to eq(:unknown)
      expect(result.projects.first.coverage_reason).to be_present
      expect(result.next_actions).to include(a_string_matching(/Retry the diagnosis/))
    end

    # @spec QUEUE-DIAG-001 @spec QUEUE-DIAG-009
    it "gives unknown coverage precedence over another project's runnable work" do
      project.update!(last_issue_sync_at: 2.days.ago)
      visible_project = create(:project, account: account, created_by: user, auto_pick_enabled: true,
        active: true, last_issue_sync_at: Time.current)
      create(:issue, project: visible_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.state).to eq(:unknown)
      expect(result.counts.eligible).to eq(1)
    end

    # @spec QUEUE-DIAG-009
    it "reports a failed diagnosis as unknown coverage with a recovery action" do
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to receive(:eligible_scope).and_raise(ActiveRecord::StatementInvalid, "boom")

      result = described_class.call(user: user)

      expect(result.state).to eq(:unknown)
      expect(result.failed?).to be(true)
      expect(result.recovery).to be_present
      expect(result.counts.eligible).to eq(0)
    end

    # @spec QUEUE-DIAG-009
    it "never treats a failed query as proof that no work exists" do
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to receive(:eligible_scope).and_raise(ActiveRecord::StatementInvalid, "boom")

      result = described_class.call(user: user)

      expect(result.state).not_to eq(:healthy)
    end

    # @spec QUEUE-DIAG-011
    it "does not diagnose projects the user cannot see" do
      other_user = create(:user, account: account)
      other_project = create(:project, account: account, created_by: other_user, auto_pick_enabled: true,
        active: true, last_issue_sync_at: Time.current)
      create(:issue, project: other_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.projects.map { |diagnosis| diagnosis.project.id }).to eq([ project.id ])
    end

    # @spec QUEUE-DIAG-012
    it "does not diagnose another tenant's issues" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_project = create(:project, account: other_account, created_by: other_user, auto_pick_enabled: true,
        active: true, last_issue_sync_at: Time.current)
      create(:issue, project: other_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.projects.map { |diagnosis| diagnosis.project.id }).not_to include(other_project.id)
      expect(result.blockers.map { |detail| detail.issue.project_id }).not_to include(other_project.id)
    end

    # @spec QUEUE-DIAG-007
    it "does not reconcile a planning hold while rendering" do
      expect(FeatureIntents::ReleaseIssue).not_to receive(:call)

      described_class.call(user: user)
    end

    # @spec QUEUE-DIAG-002
    it "counts a queued run's issue as queued work, not as an eligible candidate" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:agent_run, :queued, :automatic, project: project, issue: issue, goal: "create_pr", auto_pick: true)

      result = described_class.call(user: user)

      expect(result.counts.eligible).to eq(0)
      expect(result.counts.queued).to eq(1)
    end
  end
end
