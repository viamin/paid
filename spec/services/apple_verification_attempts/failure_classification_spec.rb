# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-ATTEMPT-009
RSpec.describe AppleVerificationAttempts::FailureClassification do
  it "accepts every value in the closed taxonomy" do
    AppleVerificationAttempts::FailureClassification::TAXONOMY.each do |classification|
      expect(described_class.classify(classification)).to eq(classification)
    end
  end

  it "rejects classifications outside the closed taxonomy" do
    expect { described_class.classify("code_defect") }
      .to raise_error(described_class::InvalidClassificationError, /unknown Apple verification failure classification/)
  end

  it "classifies capacity, worker, and cancellation/timeout as infrastructure results" do
    %w[capacity_or_quota worker_infrastructure cancellation_or_timeout].each do |value|
      expect(described_class.new(value)).to be_infrastructure
      expect(described_class.new(value)).not_to be_project
    end
  end

  it "classifies project and network-policy failures as project outcomes" do
    %w[project_configuration compile_or_link test_assertion launch_or_ui_flow required_capture network_policy unsupported_capability].each do |value|
      expect(described_class.new(value)).to be_project
      expect(described_class.new(value)).not_to be_infrastructure
    end
  end

  it "treats blank classifications as nil without raising" do
    expect(described_class.classify(nil)).to be_nil
    expect(described_class.classify("")).to be_nil
  end
end
