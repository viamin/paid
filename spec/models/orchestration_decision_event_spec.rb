# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationDecisionEvent do
  describe "validations" do
    it "requires a valid action and status" do
      event = build(:orchestration_decision_event, action: "invalid", status: "unknown")

      expect(event).not_to be_valid
      expect(event.errors[:action]).to be_present
      expect(event.errors[:status]).to be_present
    end

    it "requires an issue or agent_run" do
      event = build(:orchestration_decision_event, issue: nil, agent_run: nil)

      expect(event).not_to be_valid
      expect(event.errors[:base]).to include("issue or agent_run must be present")
    end
  end

  describe ".record!" do
    it "assigns sequential retry numbers for the same issue" do
      project = create(:project)
      issue = create(:issue, project: project)

      first = described_class.record!(
        project: project,
        issue: issue,
        decision_point: "review_goal_retry",
        action: "retry",
        status: "applied"
      )
      second = described_class.record!(
        project: project,
        issue: issue,
        decision_point: "review_goal_retry",
        action: "retry",
        status: "applied"
      )

      expect(first.sequence).to eq(1)
      expect(second.sequence).to eq(2)
    end

    it "stores json payloads with string keys" do
      project = create(:project)
      issue = create(:issue, project: project)

      event = described_class.record!(
        project: project,
        issue: issue,
        decision_point: "review_goal_retry",
        action: "retry",
        status: "noop",
        signals: { expected_count: 1 },
        result: { review_goal_retry_count: 1 }
      )

      expect(event.signals).to eq("expected_count" => 1)
      expect(event.result).to eq("review_goal_retry_count" => 1)
    end
  end
end
