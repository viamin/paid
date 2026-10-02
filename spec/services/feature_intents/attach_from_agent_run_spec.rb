# frozen_string_literal: true

require "rails_helper"

# @spec FEATURE-APPROVAL-014 @spec FEATURE-APPROVAL-015 @spec FEATURE-APPROVAL-016 @spec FEATURE-APPROVAL-017 @spec FEATURE-APPROVAL-018
RSpec.describe FeatureIntents::AttachFromAgentRun do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account) }
  let(:brief_issue) { create(:issue, project: project) }
  let(:agent_run) do
    create(:agent_run, project: project, issue: brief_issue, external_metadata: {
      "feature_brief" => { "title" => "Add dark mode", "problem" => "Reduce eye strain at night" }
    })
  end

  describe ".call" do
    it "creates a FeatureIntent in the discovering state and links the brief issue" do
      result = described_class.call(agent_run: agent_run, goal: "create_feature", brief: { "title" => "Add dark mode", "problem" => "Reduce eye strain" })

      feature_intent = result.feature_intent
      expect(feature_intent).to be_persisted
      expect(feature_intent.project).to eq(project)
      expect(feature_intent.status).to eq("discovering")
      expect(feature_intent.criteria_clarity_state).to eq("pending")
      expect(feature_intent.brief).to include("Add dark mode")
      expect(feature_intent.issues).to include(brief_issue)
    end

    it "returns the existing FeatureIntent when called twice on the same run/brief" do
      first = described_class.call(agent_run: agent_run, goal: "create_feature", brief: { "title" => "X" })

      expect {
        @second = described_class.call(agent_run: agent_run, goal: "create_feature", brief: { "title" => "X" })
      }.not_to change(FeatureIntent, :count)

      expect(@second.feature_intent).to eq(first.feature_intent)
    end

    it "is a no-op for agent runs that are not create_feature or lid_planning" do
      run = create(:agent_run, project: project, goal: "create_pr")

      expect {
        @result = described_class.call(agent_run: run, goal: "create_pr", brief: { "title" => "noop" })
      }.not_to change(FeatureIntent, :count)

      expect(@result.feature_intent).to be_nil
    end

    it "stores the brief as text on the FeatureIntent so the Inbox detail view shows it" do
      brief = { "title" => "Dark mode", "problem" => "Eye strain at night", "done_criteria" => "Toggle persists" }

      result = described_class.call(agent_run: agent_run, goal: "create_feature", brief: brief)

      expect(result.feature_intent.brief).to include("Dark mode")
      expect(result.feature_intent.brief).to include("Eye strain at night")
      expect(result.feature_intent.brief).to include("Toggle persists")
    end
  end

  describe "design PR attachment" do
    let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }

    it "records a FeatureIntentDesignPr with design_pr_kind rdr and the PR number + head SHA from GitHub" do
      result = described_class.attach_design_pr(
        feature_intent: feature_intent,
        pull_request_number: 42,
        head_sha: "a" * 40,
        design_pr_kind: "rdr",
        required: true
      )

      expect(result.design_pr).to be_persisted
      expect(result.design_pr.feature_intent).to eq(feature_intent)
      expect(result.design_pr.pull_request_number).to eq(42)
      expect(result.design_pr.head_sha).to eq("a" * 40)
      expect(result.design_pr.reviewed_head_sha).to eq("a" * 40)
      expect(result.design_pr.design_pr_kind).to eq("rdr")
      expect(result.design_pr.required).to be(true)
    end

    it "records a lid_planning design PR with required: true for LID-mode projects" do
      project.update!(lid_mode: "full")

      result = described_class.attach_design_pr(
        feature_intent: feature_intent,
        pull_request_number: 17,
        head_sha: "c" * 40,
        design_pr_kind: "lid_planning"
      )

      expect(result.design_pr.design_pr_kind).to eq("lid_planning")
      expect(result.design_pr.required).to be(true)
    end

    it "records a lid_planning design PR with required: false for non-LID projects" do
      project.update!(lid_mode: nil)

      result = described_class.attach_design_pr(
        feature_intent: feature_intent,
        pull_request_number: 17,
        head_sha: "c" * 40,
        design_pr_kind: "lid_planning"
      )

      expect(result.design_pr.design_pr_kind).to eq("lid_planning")
      expect(result.design_pr.required).to be(false)
    end

    it "is idempotent — a second call with the same pull_request_number does not duplicate" do
      described_class.attach_design_pr(
        feature_intent: feature_intent,
        pull_request_number: 42,
        head_sha: "a" * 40,
        design_pr_kind: "rdr",
        required: true
      )

      expect {
        described_class.attach_design_pr(
          feature_intent: feature_intent,
          pull_request_number: 42,
          head_sha: "b" * 40,
          design_pr_kind: "rdr",
          required: true
        )
      }.not_to change(feature_intent.feature_intent_design_prs, :count)
    end

    it "updates the head_sha when a fresh call reports a new commit SHA on the same PR" do
      described_class.attach_design_pr(
        feature_intent: feature_intent,
        pull_request_number: 42,
        head_sha: "a" * 40,
        design_pr_kind: "rdr",
        required: true
      )

      result = described_class.attach_design_pr(
        feature_intent: feature_intent,
        pull_request_number: 42,
        head_sha: "b" * 40,
        design_pr_kind: "rdr",
        required: true
      )

      expect(result.design_pr.head_sha).to eq("b" * 40)
      expect(result.design_pr.reviewed_head_sha).to eq("a" * 40)
    end
  end

  describe "issue tree attachment" do
    let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }

    it "links an implementation issue filed by the run to the FeatureIntent via FeatureIntentIssue" do
      implementation_issue = create(:issue, project: project)

      result = described_class.attach_issue(
        feature_intent: feature_intent,
        issue: implementation_issue
      )

      expect(result.feature_intent_issue).to be_persisted
      expect(result.feature_intent_issue.feature_intent).to eq(feature_intent)
      expect(result.feature_intent_issue.issue).to eq(implementation_issue)
    end

    it "is idempotent — linking the same issue twice does not duplicate the row" do
      implementation_issue = create(:issue, project: project)

      described_class.attach_issue(feature_intent: feature_intent, issue: implementation_issue)

      expect {
        described_class.attach_issue(feature_intent: feature_intent, issue: implementation_issue)
      }.not_to change(feature_intent.feature_intent_issues, :count)
    end
  end

  describe "closed-unmerged reconciliation" do
    let(:feature_intent) { create(:feature_intent, :ready_for_approval, project: project) }
    let!(:design_pr) do
      create(:feature_intent_design_pr, feature_intent: feature_intent, pull_request_number: 99,
        head_sha: "d" * 40, reviewed_head_sha: "d" * 40)
    end
    let!(:implementation_issue) { create(:issue, project: project, github_state: "open") }
    let!(:link) { create(:feature_intent_issue, feature_intent: feature_intent, issue: implementation_issue) }

    it "transitions the feature to cancelled and closes linked issues when the design PR is closed unmerged" do
      result = described_class.detach_on_close!(
        feature_intent: feature_intent,
        pull_request_number: 99,
        merged: false
      )

      expect(result.feature_intent.reload.status).to eq("cancelled")
      expect(implementation_issue.reload.github_state).to eq("closed")
    end

    it "does not transition when the design PR merged successfully" do
      result = described_class.detach_on_close!(
        feature_intent: feature_intent,
        pull_request_number: 99,
        merged: true
      )

      expect(result.feature_intent.status).to eq("design_open")
      expect(implementation_issue.reload.github_state).to eq("open")
    end

    it "is a no-op when the pull_request_number is not linked to the feature" do
      result = described_class.detach_on_close!(
        feature_intent: feature_intent,
        pull_request_number: 1000,
        merged: false
      )

      expect(result.feature_intent.status).to eq("design_open")
      expect(implementation_issue.reload.github_state).to eq("open")
    end

    it "records the merged_at timestamp on the design PR when the design PR merged" do
      result = described_class.detach_on_close!(
        feature_intent: feature_intent,
        pull_request_number: 99,
        merged: true
      )

      expect(design_pr.reload.merged_at).to be_present
    end
  end
end