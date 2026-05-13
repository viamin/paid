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

    it "returns metadata for focused agent runs" do
      definition = described_class.definition(:focused_agent_runs)

      expect(definition.owner).to eq("agent-runs")
      expect(definition.intent).to include("focused agent runs")
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

    it "uses tenant feature overrides before flipper gates" do
      create(:tenant_setting, account: project.account, features: { "explicit_pr_automation_decisions" => true })

      expect(described_class.enabled?(:explicit_pr_automation_decisions, project:)).to be(true)
    end

    it "uses false tenant feature overrides before flipper gates" do
      create(:tenant_setting, account: project.account, features: { "explicit_pr_automation_decisions" => false })
      described_class.enable!(:explicit_pr_automation_decisions, project:)

      expect(described_class.enabled?(:explicit_pr_automation_decisions, project:)).to be(false)
    end

    it "ignores non-boolean tenant feature overrides" do
      create(:tenant_setting, account: project.account, features: { "explicit_pr_automation_decisions" => "false" })
      described_class.enable!(:explicit_pr_automation_decisions, project:)

      expect(described_class.enabled?(:explicit_pr_automation_decisions, project:)).to be(true)
    end
  end

  describe ".focused_agent_runs?" do
    it "returns the focused-agent-runs state for a project" do
      expect(described_class.focused_agent_runs?(project:)).to be(false)

      described_class.enable!(:focused_agent_runs, project:)

      expect(described_class.focused_agent_runs?(project:)).to be(true)
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

  describe ".enable_percentage_of_actors" do
    it "configures a percentage-of-actors rollout" do
      described_class.enable_percentage_of_actors(:explicit_pr_automation_decisions, 25)

      expect(described_class.rollout_status(:explicit_pr_automation_decisions)).to include(
        percentage_of_actors: 25,
        percentage_of_time: 0
      )
    end

    it "clears the percentage gate when set to zero" do
      described_class.enable_percentage_of_actors(:explicit_pr_automation_decisions, 25)

      described_class.enable_percentage_of_actors(:explicit_pr_automation_decisions, 0)

      expect(described_class.rollout_status(:explicit_pr_automation_decisions)[:percentage_of_actors]).to eq(0)
    end

    it "rejects invalid percentages" do
      expect {
        described_class.enable_percentage_of_actors(:explicit_pr_automation_decisions, 101)
      }.to raise_error(described_class::InvalidPercentageError, /between 0 and 100/)
    end
  end

  describe ".enable_percentage_of_time" do
    it "configures a percentage-of-time rollout" do
      described_class.enable_percentage_of_time(:explicit_pr_automation_decisions, 10)

      expect(described_class.rollout_status(:explicit_pr_automation_decisions)).to include(
        percentage_of_actors: 0,
        percentage_of_time: 10
      )
    end
  end

  describe ".rollout_status" do
    it "returns the configured boolean, actor, group, and percentage gates" do
      described_class.enable!(:explicit_pr_automation_decisions)
      described_class.enable!(:explicit_pr_automation_decisions, project:)
      described_class.enable_percentage_of_actors(:explicit_pr_automation_decisions, 25)
      described_class.enable_percentage_of_time(:explicit_pr_automation_decisions, 10)
      described_class.flipper[:explicit_pr_automation_decisions].enable_group(:beta)

      expect(described_class.rollout_status(:explicit_pr_automation_decisions)).to eq(
        boolean: true,
        percentage_of_actors: 25,
        percentage_of_time: 10,
        actors: [ project.flipper_id ],
        groups: [ "beta" ]
      )
    end
  end

  describe ".snapshot" do
    it "returns the current boolean state for every registered flag" do
      described_class.enable!(:explicit_pr_automation_decisions, project:)

      expect(described_class.snapshot(project:)).to eq(
        explicit_pr_automation_decisions: true,
        focused_agent_runs: false
      )
    end
  end
end
