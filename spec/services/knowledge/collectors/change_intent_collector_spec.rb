# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Collectors::ChangeIntentCollector do
  subject(:collector) do
    described_class.new(project:, project_version:, collector_run:, options: {})
  end

  let(:project) { create(:project) }
  let(:project_version) { create(:project_version, project:) }
  let(:collector_run) { create(:collector_run, project_version:, collector_type: "change_intent") }

  describe "#collect" do
    it "returns only active change intents" do
      create(:change_intent, project:, title: "Active CIR")
      create(:change_intent, :draft, project:, title: "Draft CIR")

      artifacts = collector.collect

      expect(artifacts.pluck(:identifier)).to eq([ "Active CIR" ])
      expect(artifacts.first[:artifact_type]).to eq("change_intent")
    end
  end
end
