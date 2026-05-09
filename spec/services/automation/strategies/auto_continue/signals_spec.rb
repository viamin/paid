# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoContinue::Signals do
  def lifecycle_payload(**overrides)
    {
      issue_id: 1,
      pr_number: 42,
      phase: "ready",
      active_run_exists: false,
      operational_failure_breaker: false,
      draft_review_limit_reached: false,
      consecutive_draft_failures_breaker: false,
      review_goal_retry_limit_requires_escalation: false,
      followup_limit_reached: false,
      escalation_dismissed: false,
      owner_reviewer_login: nil,
      escalation_reason: nil,
      draft_review_count: 0,
      review_goal_retry_count: 0,
      pr_followup_count: 0,
      draft: false
    }.merge(overrides)
  end

  describe ".from_metadata" do
    it "returns nil when metadata is nil" do
      expect(described_class.from_metadata(nil)).to be_nil
    end

    it "returns nil when metadata has no lifecycle key" do
      expect(described_class.from_metadata({ scan: {} })).to be_nil
    end

    it "builds signals from lifecycle metadata" do
      lifecycle = lifecycle_payload(
        phase: "draft",
        active_run_exists: true,
        owner_reviewer_login: "alice",
        draft_review_count: 2,
        review_goal_retry_count: 1,
        pr_followup_count: 3,
        draft: true
      )
      scan = { triggers: [] }
      signals = described_class.from_metadata(lifecycle: lifecycle, scan: scan)

      expect(signals).to have_attributes(
        issue_id: 1, pr_number: 42, phase: "draft",
        active_run_exists: true, operational_failure_breaker: false,
        owner_reviewer_login: "alice",
        draft_review_count: 2,
        review_goal_retry_count: 1,
        pr_followup_count: 3,
        scan: scan
      )
    end

    it "coerces boolean fields strictly" do
      lifecycle = lifecycle_payload(
        active_run_exists: nil,
        operational_failure_breaker: "yes",
        draft_review_limit_reached: 1,
        draft_review_count: "4",
        review_goal_retry_count: "2",
        pr_followup_count: "1",
        draft: nil
      )

      signals = described_class.from_metadata(lifecycle: lifecycle)

      expect(signals.active_run_exists).to be false
      expect(signals.operational_failure_breaker).to be false
      expect(signals.draft_review_limit_reached).to be false
      expect(signals.draft_review_count).to eq(4)
      expect(signals.review_goal_retry_count).to eq(2)
      expect(signals.pr_followup_count).to eq(1)
      expect(signals.draft).to be false
    end
  end

  describe "phase predicates" do
    def build_signals(phase:)
      described_class.from_metadata(lifecycle: lifecycle_payload(phase: phase))
    end

    it "reports draft_phase? for draft" do
      signals = build_signals(phase: "draft")
      expect(signals.draft_phase?).to be true
      expect(signals.ready_phase?).to be false
      expect(signals.escalated_phase?).to be false
    end

    it "reports draft_phase? for restarted" do
      signals = build_signals(phase: "restarted")
      expect(signals.draft_phase?).to be true
    end

    it "reports ready_phase? for ready" do
      signals = build_signals(phase: "ready")
      expect(signals.ready_phase?).to be true
      expect(signals.draft_phase?).to be false
    end

    it "reports escalated_phase? for escalated" do
      signals = build_signals(phase: "escalated")
      expect(signals.escalated_phase?).to be true
      expect(signals.ready_phase?).to be false
    end
  end
end
