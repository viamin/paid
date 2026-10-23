# frozen_string_literal: true

require "rails_helper"

RSpec.describe DeliveryTelemetry::ProjectReport do
  describe ".call" do
    # @spec DELIVERY-TELEMETRY-001, DELIVERY-TELEMETRY-002
    it "reports completed feature cycles, human touches, and stale approval churn" do
      project, feature, implementation_pr = completed_feature_with_stale_approval

      report = described_class.call(project:)
      cycle = report.fetch(:completed_features).fetch(0)

      expect(cycle).to include(feature_intent_id: feature.id, decisions_resolved_count: 1,
        stale_approval_count: 1, implementation_merged_at: implementation_pr.closed_at)
      expect(cycle.fetch(:cycle_time_seconds)).to be > 0
      expect(report.dig(:approval_loop, :time_to_clear_by_blocker)).to include(
        include(code: "unresolved_questions", count: 1)
      )
    end

    # @spec DELIVERY-TELEMETRY-003
    it "computes escaped drift from merged within-scope verdicts and later amendments" do
      project = create(:project)
      feature = create(:feature_intent, project:, status: "released", approved_design_revision: "new-revision")
      pr = create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged", closed_at: 2.days.ago)
      feature.feature_intent_issues.create!(issue: pr)
      verdict = create(:intent_conformance_verdict, project:, issue: pr, reviewer_model: "reviewer-a",
        approved_design_revision: "old-revision", evaluated_at: 3.days.ago)
      create(:design_amendment, feature_intent: feature, project:, superseded_revision: verdict.approved_design_revision,
        created_at: 1.day.ago)

      report = described_class.call(project:)

      expect(report.dig(:escaped_drift, :project)).to include(denominator: 1, numerator: 1, rate: 1.0)
      expect(report.dig(:escaped_drift, :by_reviewer_model)).to include(
        include(reviewer_model: "reviewer-a", denominator: 1, numerator: 1, rate: 1.0)
      )
    end

    # @spec DELIVERY-TELEMETRY-004
    it "compares pre-activation and post-activation delivery time" do
      project = create(:project)
      activation_at = 3.days.ago
      create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged",
        github_created_at: 6.days.ago, closed_at: 5.days.ago)
      create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged",
        github_created_at: 2.days.ago, closed_at: 1.day.ago)

      report = described_class.call(project:, enforcement_activated_at: activation_at)

      expect(report.dig(:delivery_time, :baseline, :count)).to eq(1)
      expect(report.dig(:delivery_time, :post_activation, :count)).to eq(1)
    end

    private

    def completed_feature_with_stale_approval
      project = create(:project)
      feature = create(:feature_intent, project:, status: "released", approved_at: 4.days.ago,
        approved_revision_recorded_at: 3.days.ago, approved_pr_heads: { "7" => "approved-head" })
      create(:feature_intent_approval_revision, feature_intent: feature, approved_at: 4.days.ago,
        pr_heads: { "7" => "approved-head" }, revision_number: 1)
      create(:feature_intent_design_pr, feature_intent: feature, pull_request_number: 7, head_sha: "current-head")
      resolve_question(feature)
      implementation_pr = merged_pr(project, created_at: 2.days.ago, closed_at: 1.day.ago)
      feature.feature_intent_issues.create!(issue: implementation_pr)
      create(:agent_run, project:, issue: implementation_pr, goal: "create_feature", started_at: 6.days.ago)
      AccountActivityEvent.create!(account: project.account, action: "feature_intent.released", subject: feature, created_at: 3.days.ago)
      [ project, feature, implementation_pr ]
    end

    def resolve_question(feature)
      decision = create(:feature_intent_decision, feature_intent: feature, created_at: 5.days.ago)
      decision.update!(status: "resolved", resolved_at: 4.days.ago, resolved_by: create(:user))
    end

    def merged_pr(project, created_at:, closed_at:)
      create(:issue, :pull_request, project:, github_state: "closed", pr_review_phase: "merged",
        github_created_at: created_at, closed_at:)
    end
  end
end
