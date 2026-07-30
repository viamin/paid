# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecks::Checks::Project::ReviewWithoutBot do
  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(configured)
  end

  let(:review_settings) do
    {
      "enabled" => true,
      "methods" => {
        "paid_agent" => { "enabled" => true }
      }
    }
  end

  context "when the review bot is not configured" do
    let(:configured) { false }

    it "returns a finding" do
      project = build(:project, review_settings: review_settings)

      expect(described_class.call(project)).to contain_exactly(
        have_attributes(
          check: described_class.name,
          scope: :project,
          severity: :error,
          message: "Paid Agent review is enabled but the paid-code-reviewer GitHub App is not configured."
        )
      )
    end
  end

  context "when the review bot is configured" do
    let(:configured) { true }

    it "returns no findings" do
      project = build(:project, review_settings: review_settings)

      expect(described_class.call(project)).to eq([])
    end
  end
end
