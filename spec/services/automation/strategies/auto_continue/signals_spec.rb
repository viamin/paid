# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoContinue::Signals, :no_db do
  def lifecycle_payload(**overrides)
    {
      issue_id: 1,
      pr_number: 42,
      phase: "ready",
      active_run_exists: false,
      operational_failure_breaker: false,
      no_progress_stuck: false,
      failure_streak_limit_reached: false,
      escalation_dismissed: false,
      owner_reviewer_login: nil,
      escalation_reason: nil,
      consecutive_unsuccessful_automatic_runs: 0,
      consecutive_operational_failures: 0,
      last_meaningful_progress_at: nil,
      draft_review_count: 0,
      review_goal_retry_count: 0,
      pr_followup_count: 0,
      draft: false
    }.merge(overrides)
  end

  def string_keyed_metadata(lifecycle:, scan: nil)
    { "lifecycle" => lifecycle.transform_keys(&:to_s), "scan" => scan }
  end

  def draft_string_keyed_payload
    {
      phase: "draft",
      active_run_exists: true,
      no_progress_stuck: false,
      failure_streak_limit_reached: true,
      consecutive_unsuccessful_automatic_runs: 2,
      draft: true,
      scan: { "triggers" => [] }
    }
  end

  def numeric_and_non_boolean_lifecycle_payload
    lifecycle_payload(
      active_run_exists: nil,
      operational_failure_breaker: "yes",
      no_progress_stuck: 1,
      failure_streak_limit_reached: 1,
      consecutive_unsuccessful_automatic_runs: "4",
      draft_review_count: "4",
      review_goal_retry_count: "2",
      pr_followup_count: "1",
      draft: nil
    )
  end

  describe ".from_metadata" do
    it "returns nil when metadata is nil" do
      expect(described_class.from_metadata(nil)).to be_nil
    end

    it "returns nil when metadata has no lifecycle key" do
      expect(described_class.from_metadata({ scan: {} })).to be_nil
    end

    it "builds signals from lifecycle metadata" do
      lifecycle = lifecycle_payload(phase: "draft", active_run_exists: true, owner_reviewer_login: "alice",
        consecutive_unsuccessful_automatic_runs: 2, draft_review_count: 2,
        review_goal_retry_count: 1, pr_followup_count: 3, draft: true)
      scan = { triggers: [] }
      signals = described_class.from_metadata(lifecycle: lifecycle, scan: scan)

      expect(signals.to_h.slice(
        :issue_id, :pr_number, :phase, :active_run_exists, :operational_failure_breaker,
        :no_progress_stuck,
        :owner_reviewer_login, :consecutive_unsuccessful_automatic_runs, :draft_review_count,
        :review_goal_retry_count, :pr_followup_count, :scan
      )).to eq(
        issue_id: 1, pr_number: 42, phase: "draft", active_run_exists: true,
        operational_failure_breaker: false, no_progress_stuck: false, owner_reviewer_login: "alice",
        consecutive_unsuccessful_automatic_runs: 2, draft_review_count: 2,
        review_goal_retry_count: 1, pr_followup_count: 3, scan: scan
      )
    end

    it "accepts string-keyed metadata from serialized workflow payloads" do
      payload = draft_string_keyed_payload
      signals = described_class.from_metadata(string_keyed_metadata(
        lifecycle: lifecycle_payload(
          phase: payload[:phase],
          active_run_exists: payload[:active_run_exists],
          failure_streak_limit_reached: payload[:failure_streak_limit_reached],
          consecutive_unsuccessful_automatic_runs: payload[:consecutive_unsuccessful_automatic_runs],
          draft: payload[:draft]
        ),
        scan: payload[:scan]
      ))

      expect(signals.to_h.slice(
        :phase,
        :active_run_exists,
        :no_progress_stuck,
        :failure_streak_limit_reached,
        :consecutive_unsuccessful_automatic_runs,
        :draft,
        :scan
      )).to eq(payload)
    end

    it "coerces boolean fields strictly" do
      signals = described_class.from_metadata(lifecycle: numeric_and_non_boolean_lifecycle_payload)

      expect(signals.active_run_exists).to be false
      expect(signals.operational_failure_breaker).to be false
      expect(signals.no_progress_stuck).to be false
      expect(signals.failure_streak_limit_reached).to be false
      expect(signals.consecutive_unsuccessful_automatic_runs).to eq(4)
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
