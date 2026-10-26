# frozen_string_literal: true

require "rails_helper"

# @spec QUEUE-DIAG-004 @spec QUEUE-DIAG-005 @spec QUEUE-DIAG-006
# @spec QUEUE-DIAG-007 @spec QUEUE-DIAG-008 @spec QUEUE-DIAG-012
RSpec.describe QueueStalls::Sweep do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
  end
  let(:github_client) do
    instance_double(GithubClient,
      add_labels_to_issue: nil,
      remove_label_from_issue: nil,
      remove_labels_from_issue: nil)
  end

  before do
    allow(project).to receive(:client).and_return(github_client)
  end

  describe ".call" do
    # @spec QUEUE-DIAG-004
    it "recovers eligible work that was never handed to the scheduler" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")

      result = described_class.call(account: account)

      expect(result.recovered).to eq(1)
      expect(issue.agent_runs.reload.where(status: "queued").count).to eq(1)
    end

    # @spec QUEUE-DIAG-004
    it "does not recover work when the project does not admit automatic work" do
      project.update!(auto_pick_enabled: false)
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")

      result = described_class.call(account: account)

      expect(result.detected).to eq(0)
      expect(issue.agent_runs.reload.count).to eq(0)
    end

    # @spec QUEUE-DIAG-004
    it "does not recover work for a paused project" do
      project.update!(paused: true)
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")

      described_class.call(account: account)

      expect(issue.agent_runs.reload.count).to eq(0)
    end

    # @spec QUEUE-DIAG-012
    it "does not touch another tenant's issues" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_project = create(:project, account: other_account, created_by: other_user,
        auto_pick_enabled: true, active: true)
      other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "new")

      described_class.call(account: account)

      expect(other_issue.agent_runs.reload.count).to eq(0)
    end

    # @spec QUEUE-DIAG-004
    it "reassesses a stale planning handoff through the hold-reassessment service" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "planning" ])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: issue, release_state: "held")

      described_class.call(account: account)

      assessment = QueueStallAssessment.find_by(issue_id: issue.id, reason_code: "stale_planning_hold")
      expect(assessment).to be_present
      expect(assessment.outcome).to eq("observed")

      assessment.update!(created_at: 2.hours.ago)

      expect(FeatureIntents::ReleaseIssue).to receive(:call).with(issue: issue).and_call_original

      described_class.call(account: account)

      expect(QueueStallAssessment.find_by(issue_id: issue.id, reason_code: "stale_planning_hold").outcome)
        .to eq("blocked")
    end

    # @spec QUEUE-DIAG-005
    it "does not repeat the recovery for an unchanged state" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "planning" ])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: issue, release_state: "held")

      described_class.call(account: account)
      QueueStallAssessment.find_by(issue_id: issue.id, reason_code: "stale_planning_hold")
        .update!(created_at: 2.hours.ago)

      described_class.call(account: account)

      expect(FeatureIntents::ReleaseIssue).not_to receive(:call)

      result = described_class.call(account: account)

      expect(result.skipped).to be >= 1
    end

    # @spec QUEUE-DIAG-005
    it "records the state digest so an unchanged state is assessed once" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "planning" ])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: issue, release_state: "held")

      described_class.call(account: account)
      described_class.call(account: account)

      assessments = QueueStallAssessment.where(issue_id: issue.id, reason_code: "stale_planning_hold")
      expect(assessments.count).to eq(1)
    end

    # @spec QUEUE-DIAG-006
    it "bounds the failures so the same state is not retried forever" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "planning" ])
      feature = create(:feature_intent, :confidence_driven, project: project)
      create(:feature_intent_issue, feature_intent: feature, issue: issue, release_state: "held")

      described_class.call(account: account)
      assessment = QueueStallAssessment.find_by(issue_id: issue.id, reason_code: "stale_planning_hold")
      assessment.update!(created_at: 2.hours.ago, assessed_at: 2.hours.ago, attempt_count: 3)

      expect(FeatureIntents::ReleaseIssue).not_to receive(:call)

      result = described_class.call(account: account)

      expect(result.skipped).to eq(1)
    end

    # @spec QUEUE-DIAG-007
    it "delegates a semantic delivery assessment to the agent_harness recovery path" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "new")
      run = create(:agent_run, :completed, :automatic, project: project, issue: issue, goal: "create_pr",
        auto_pick: true, pull_request_number: 4242, pull_request_url: "https://github.com/owner/repo/pull/4242")
      create(:issue, :pull_request, project: project, parent_issue: issue, github_number: 4242,
        pr_review_phase: "merged")

      described_class.call(account: account)
      QueueStallAssessment.find_by(issue_id: issue.id, reason_code: "unresolved_delivery")
        .update!(created_at: 2.hours.ago)

      expect(PartialCloseouts::ReconcileLegacy).to receive(:reconcile_run).with(run).and_return(:reconciled)

      described_class.call(account: account)

      assessment = QueueStallAssessment.find_by(issue_id: issue.id, reason_code: "unresolved_delivery")
      expect(assessment.outcome).to eq("recovered")
    end

    # @spec QUEUE-DIAG-006
    it "bounds the semantic recoveries performed by one sweep" do
      issues = Array.new(3) do
        issue = create(:issue, project: project, github_state: "open", paid_state: "new")
        create(:agent_run, :completed, :automatic, project: project, issue: issue, goal: "create_pr",
          auto_pick: true, pull_request_number: issue.github_number + 1000,
          pull_request_url: "https://github.com/owner/repo/pull/#{issue.github_number + 1000}")
        create(:issue, :pull_request, project: project, parent_issue: issue,
          github_number: issue.github_number + 1000, pr_review_phase: "merged")
        issue
      end

      described_class.call(account: account)
      QueueStallAssessment.where(reason_code: "unresolved_delivery").update_all(created_at: 2.hours.ago)

      allow(PartialCloseouts::ReconcileLegacy).to receive(:reconcile_run).and_return(:reconciled)

      described_class.call(account: account)

      expect(PartialCloseouts::ReconcileLegacy).to have_received(:reconcile_run).exactly(2).times
      expect(issues.size).to eq(3)
    end
  end
end
