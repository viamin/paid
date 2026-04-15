# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureFlags do
  let(:project) { create(:project) }

  before do
    described_class.flipper.features.each(&:remove)
  end

  describe ".definition" do
    it "returns metadata for registered flags" do
      definition = described_class.definition(:explicit_pr_automation_decisions)

      expect(definition.owner).to eq("infrastructure")
      expect(definition.intent).to include("#1077")
    end

    it "raises for unknown flags" do
      expect {
        described_class.definition(:missing_flag)
      }.to raise_error(described_class::UnknownFlagError, /missing_flag/)
    end
  end

  describe ".enabled?" do
    it "returns global flag state" do
      expect(described_class.enabled?(:explicit_pr_automation_decisions)).to be(false)

      described_class.enable!(:explicit_pr_automation_decisions)

      expect(described_class.enabled?(:explicit_pr_automation_decisions)).to be(true)
    end

    it "supports project-scoped rollout checks" do
      described_class.enable!(:explicit_pr_automation_decisions, project:)

      expect(described_class.enabled?(:explicit_pr_automation_decisions, project:)).to be(true)
      expect(described_class.enabled?(:explicit_pr_automation_decisions)).to be(false)
    end
  end

  describe ".disable!" do
    it "clears actor gates when disabling globally" do
      described_class.enable!(:explicit_pr_automation_decisions, project:)
      expect(described_class.enabled?(:explicit_pr_automation_decisions, project:)).to be(true)

      described_class.disable!(:explicit_pr_automation_decisions)

      expect(described_class.enabled?(:explicit_pr_automation_decisions, project:)).to be(false)
    end
  end

  describe ".snapshot" do
    it "returns the current boolean state for every registered flag" do
      described_class.enable!(:explicit_pr_automation_decisions, project:)

      expect(described_class.snapshot(project:)).to eq(
        explicit_pr_automation_decisions: true
      )
    end
  end
end
