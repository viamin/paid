# frozen_string_literal: true

require "rails_helper"

# @spec TRUSTED-MEASUREMENTS-001
RSpec.describe TrustedMeasurementAttempt do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:) }

  it "is valid with an allowlisted check key" do
    attempt = build(:trusted_measurement_attempt, project:, issue:)

    expect(attempt).to be_valid
  end

  it "rejects a check key outside the allowlist" do
    attempt = build(:trusted_measurement_attempt, project:, issue:, check_key: "drop_all_tables")

    expect(attempt).not_to be_valid
    expect(attempt.errors[:check_key]).to be_present
  end

  it "rejects an issue that does not belong to the attempt's project" do
    other_project = create(:project, account: project.account)
    attempt = build(:trusted_measurement_attempt, project:, issue: create(:issue, project: other_project))

    expect(attempt).not_to be_valid
    expect(attempt.errors[:issue]).to be_present
  end

  it "rejects an account that does not match the project's account" do
    attempt = build(:trusted_measurement_attempt, project:, issue:, account: create(:account))

    expect(attempt).not_to be_valid
    expect(attempt.errors[:account]).to be_present
  end

  describe "#current_for_revision?" do
    it "is true only when the attempt's deployed revision matches the given revision" do
      attempt = build(:trusted_measurement_attempt, project:, issue:, deployed_revision: "rev-1")

      expect(attempt.current_for_revision?("rev-1")).to be(true)
      expect(attempt.current_for_revision?("rev-2")).to be(false)
    end

    it "is false when either revision is unknown" do
      attempt = build(:trusted_measurement_attempt, project:, issue:, deployed_revision: nil)

      expect(attempt.current_for_revision?("rev-1")).to be(false)
      expect(build(:trusted_measurement_attempt, project:, issue:, deployed_revision: "rev-1").current_for_revision?(nil)).to be(false)
    end
  end
end
