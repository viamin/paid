# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-006
RSpec.describe TrustedMeasurements::Evidence do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }

  around do |example|
    previous = ENV["PAID_DEPLOYED_REVISION"]
    example.run
  ensure
    ENV["PAID_DEPLOYED_REVISION"] = previous
  end

  describe ".records_for" do
    it "flags an attempt collected against the currently deployed revision as current" do
      ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-1")

      records = described_class.records_for(issue)

      expect(records.size).to eq(1)
      expect(records.first).to include("status" => "succeeded", "current" => true, "deployed_revision" => "rev-1")
    end

    it "flags an attempt collected against a superseded revision as not current" do
      ENV["PAID_DEPLOYED_REVISION"] = "rev-2"
      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-1")

      records = described_class.records_for(issue)

      expect(records.first).to include("current" => false)
    end

    it "returns only the latest record per check/criterion pair" do
      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-1",
        result: { "active_closed_issue_count" => 5 })
      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-2",
        result: { "active_closed_issue_count" => 0 })

      records = described_class.records_for(issue)

      expect(records.size).to eq(1)
      expect(records.first.dig("result", "active_closed_issue_count")).to eq(0)
    end

    # @spec TRUSTED-MEASUREMENTS-005
    it "prefers freshly recollected evidence for the current revision after a rollback" do
      ENV["PAID_DEPLOYED_REVISION"] = "rev-1"
      current = create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-1",
        executed_at: 2.days.ago, result: { "active_closed_issue_count" => 5 })
      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-2",
        executed_at: 1.day.ago, result: { "active_closed_issue_count" => 0 })
      current.update!(executed_at: Time.current, result: { "active_closed_issue_count" => 0 })

      records = described_class.records_for(issue)

      expect(records).to contain_exactly(hash_including(
        "deployed_revision" => "rev-1", "current" => true,
        "result" => hash_including("active_closed_issue_count" => 0)
      ))
    end

    it "returns an empty array for an issue with no trusted measurement evidence" do
      expect(described_class.records_for(issue)).to eq([])
    end
  end

  describe ".revision_for" do
    it "is nil when there is no evidence" do
      expect(described_class.revision_for(issue)).to be_nil
    end

    it "changes when the underlying evidence changes" do
      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-1")
      first_revision = described_class.revision_for(issue)

      create(:trusted_measurement_attempt, :succeeded, project:, issue:, deployed_revision: "rev-2",
        check_key: "agent_planning_hold_reconciliation_closed_count", criterion_key: "another_criterion")

      expect(described_class.revision_for(issue)).not_to eq(first_revision)
    end
  end
end
