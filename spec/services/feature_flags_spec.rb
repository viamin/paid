# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureFlags do
  let(:project) { create(:project) }
  let(:test_flag) { :test_feature_flag }
  let(:test_definition) do
    FeatureFlags::Definition.new(
      name: :test_feature_flag,
      owner: "test",
      intent: "Test flag",
      rollout_plan: "None",
      cleanup_criteria: "None"
    )
  end

  before do
    described_class.flipper.features.each(&:remove)

    stub_const("#{described_class}::DEFINITIONS", {
      test_feature_flag: test_definition
    }.freeze)
  end

  describe ".definition" do
    it "returns metadata for registered flags" do
      definition = described_class.definition(:test_feature_flag)

      expect(definition.owner).to eq("test")
    end

    it "raises for unknown flags" do
      expect {
        described_class.definition(:missing_flag)
      }.to raise_error(described_class::UnknownFlagError, /missing_flag/)
    end
  end

  describe ".enabled?" do
    it "returns global flag state" do
      expect(described_class.enabled?(:test_feature_flag)).to be(false)

      described_class.enable!(:test_feature_flag)

      expect(described_class.enabled?(:test_feature_flag)).to be(true)
    end

    it "supports project-scoped rollout checks" do
      described_class.enable!(:test_feature_flag, project:)

      expect(described_class.enabled?(:test_feature_flag, project:)).to be(true)
      expect(described_class.enabled?(:test_feature_flag)).to be(false)
    end

    it "uses tenant feature overrides before flipper gates" do
      create(:tenant_setting, account: project.account, features: { "test_feature_flag" => true })

      expect(described_class.enabled?(:test_feature_flag, project:)).to be(true)
    end

    it "uses false tenant feature overrides before flipper gates" do
      create(:tenant_setting, account: project.account, features: { "test_feature_flag" => false })
      described_class.enable!(:test_feature_flag, project:)

      expect(described_class.enabled?(:test_feature_flag, project:)).to be(false)
    end

    it "ignores non-boolean tenant feature overrides" do
      create(:tenant_setting, account: project.account, features: { "test_feature_flag" => "false" })
      described_class.enable!(:test_feature_flag, project:)

      expect(described_class.enabled?(:test_feature_flag, project:)).to be(true)
    end
  end

  describe ".disable!" do
    it "clears actor gates when disabling globally" do
      described_class.enable!(:test_feature_flag, project:)
      expect(described_class.enabled?(:test_feature_flag, project:)).to be(true)

      described_class.disable!(:test_feature_flag)

      expect(described_class.enabled?(:test_feature_flag, project:)).to be(false)
    end
  end

  describe ".enable_percentage_of_actors" do
    it "configures a percentage-of-actors rollout" do
      described_class.enable_percentage_of_actors(:test_feature_flag, 25)

      expect(described_class.rollout_status(:test_feature_flag)).to include(
        percentage_of_actors: 25,
        percentage_of_time: 0
      )
    end

    it "clears the percentage gate when set to zero" do
      described_class.enable_percentage_of_actors(:test_feature_flag, 25)

      described_class.enable_percentage_of_actors(:test_feature_flag, 0)

      expect(described_class.rollout_status(:test_feature_flag)[:percentage_of_actors]).to eq(0)
    end

    it "rejects invalid percentages" do
      expect {
        described_class.enable_percentage_of_actors(:test_feature_flag, 101)
      }.to raise_error(described_class::InvalidPercentageError, /between 0 and 100/)
    end
  end

  describe ".enable_percentage_of_time" do
    it "configures a percentage-of-time rollout" do
      described_class.enable_percentage_of_time(:test_feature_flag, 10)

      expect(described_class.rollout_status(:test_feature_flag)).to include(
        percentage_of_actors: 0,
        percentage_of_time: 10
      )
    end
  end

  describe ".rollout_status" do
    it "returns the configured boolean, actor, group, and percentage gates" do
      described_class.enable!(:test_feature_flag)
      described_class.enable!(:test_feature_flag, project:)
      described_class.enable_percentage_of_actors(:test_feature_flag, 25)
      described_class.enable_percentage_of_time(:test_feature_flag, 10)
      described_class.flipper[:test_feature_flag].enable_group(:beta)

      expect(described_class.rollout_status(:test_feature_flag)).to eq(
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
      described_class.enable!(:test_feature_flag, project:)

      expect(described_class.snapshot(project:)).to eq(
        test_feature_flag: true
      )
    end
  end
end
