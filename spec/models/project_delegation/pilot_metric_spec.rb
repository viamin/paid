# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-007
RSpec.describe ProjectDelegation::PilotMetric do
  it "has a valid factory" do
    expect(build(:project_delegation_pilot_metric)).to be_valid
  end

  it "rejects an unknown posture" do
    metric = build(:project_delegation_pilot_metric, posture: "unbounded")

    expect(metric).not_to be_valid
    expect(metric.errors[:posture]).to be_present
  end

  it "rejects a window that does not end after it starts" do
    start = 20.days.ago
    metric = build(:project_delegation_pilot_metric, window_started_at: start, window_ended_at: start)

    expect(metric).not_to be_valid
    expect(metric.errors[:window_ended_at]).to be_present
  end

  it "rejects more completed issues than measured issues" do
    metric = build(:project_delegation_pilot_metric, completed_issues: 5, total_issues: 4)

    expect(metric).not_to be_valid
    expect(metric.errors[:completed_issues]).to be_present
  end

  it "rejects a completion rate outside the 0..1 range" do
    metric = build(:project_delegation_pilot_metric, completion_rate: 1.5)

    expect(metric).not_to be_valid
    expect(metric.errors[:completion_rate]).to be_present
  end

  it "requires the intent, acceptance, and evidence revisions for revision-aware joins" do
    metric = build(:project_delegation_pilot_metric, revisions: { "intent_revision" => "rev-1" })

    expect(metric).not_to be_valid
    expect(metric.errors[:revisions]).to be_present
  end

  describe "#decisions_per_completed_issue" do
    it "divides human Inbox decisions by completed issues" do
      metric = build(:project_delegation_pilot_metric, inbox_decisions: 12, completed_issues: 30)

      expect(metric.decisions_per_completed_issue).to be_within(0.0001).of(0.4)
    end

    it "returns nil without completed issues" do
      metric = build(:project_delegation_pilot_metric, completed_issues: 0)

      expect(metric.decisions_per_completed_issue).to be_nil
    end
  end

  describe "#material_attributable_reversals" do
    it "selects only material reversals attributable to delegated work" do
      reversals = [
        { "settled_revision" => "r1", "reversing_revision" => "r2", "material" => true,
          "attributable_to_delegated_work" => true },
        { "settled_revision" => "r3", "reversing_revision" => "r4", "material" => true,
          "attributable_to_delegated_work" => false },
        { "settled_revision" => "r5", "reversing_revision" => "r6", "material" => false,
          "attributable_to_delegated_work" => true }
      ]
      metric = build(:project_delegation_pilot_metric, reversals: reversals)

      expect(metric.material_attributable_reversals.map { |r| r["settled_revision"] }).to eq(%w[r1])
    end
  end

  describe ".latest_for" do
    it "returns the most recent window for a project and posture" do
      project = create(:project)
      create(:project_delegation_pilot_metric, :conservative, project:,
        window_started_at: 60.days.ago, window_ended_at: 46.days.ago)
      newest = create(:project_delegation_pilot_metric, :conservative, project:,
        window_started_at: 30.days.ago, window_ended_at: 16.days.ago)

      expect(described_class.latest_for(project, "conservative")).to eq(newest)
    end
  end
end
