# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-001
RSpec.describe Automation::Phases do
  describe "vocabulary" do
    it "classifies responsibility into exactly six phases" do
      expect(described_class::ALL).to eq(%w[
        discovery issue_preparation coding merge release_deployment operations
      ])
    end

    it "keeps operations outside the delivery chain" do
      expect(described_class::DELIVERY_CHAIN).not_to include(described_class::OPERATIONS)
    end

    it "offers manual continuation endpoints only through merge" do
      expect(described_class::CONTINUATION_ENDPOINTS).to eq(%w[issue_preparation coding merge])
    end
  end

  describe ".chain" do
    it "covers the starting phase and every later delivery phase through the endpoint" do
      expect(described_class.chain(from_phase: "coding", through: "merge"))
        .to eq(%w[coding merge])
    end

    it "never reaches discovery from a coding start" do
      expect(described_class.chain(from_phase: "coding", through: "merge")).not_to include("discovery")
    end

    it "cannot reach release or operations through a merge endpoint" do
      chain = described_class.chain(from_phase: "coding", through: "merge")

      expect(chain).not_to include("release_deployment", "operations")
    end

    it "returns nothing when the endpoint precedes the start" do
      expect(described_class.chain(from_phase: "merge", through: "coding")).to be_empty
    end

    it "returns nothing for a non-delivery phase" do
      expect(described_class.chain(from_phase: "operations", through: "merge")).to be_empty
    end
  end

  describe ".endpoints_for" do
    it "offers the action's own phase and the later endpoints" do
      expect(described_class.endpoints_for("issue_preparation")).to eq(%w[issue_preparation coding merge])
    end

    it "offers only merge from the merge phase" do
      expect(described_class.endpoints_for("merge")).to eq(%w[merge])
    end

    it "offers nothing for operations" do
      expect(described_class.endpoints_for("operations")).to be_empty
    end
  end

  describe ".for_capability" do
    it "maps every automation capability to its owning phase" do
      expect(described_class.for_capability("auto_pick")).to eq("coding")
      expect(described_class.for_capability("auto_enhance")).to eq("issue_preparation")
      expect(described_class.for_capability("auto_merge")).to eq("merge")
      expect(described_class.for_capability("auto_release")).to eq("release_deployment")
    end

    it "returns nothing for an unknown capability" do
      expect(described_class.for_capability("nonsense")).to be_nil
    end
  end
end