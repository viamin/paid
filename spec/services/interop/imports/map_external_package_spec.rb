# frozen_string_literal: true

require "rails_helper"

RSpec.describe Interop::Imports::MapExternalPackage do
  describe ".call" do
    it "maps Cursor source data into normalized import entries" do
      result = described_class.call(
        source_system: "cursor",
        raw_data: {
          prompts: [
            { name: "Fix Bug", content: "Fix the {{issue}} bug" }
          ],
          style_guides: [
            { name: "Ruby Style", content: "Use frozen string literals", language: "ruby" }
          ]
        }
      )

      expect(result.source_system).to eq("cursor")
      expect(result.prompts.size).to eq(1)
      expect(result.prompts.first[:name]).to eq("Fix Bug")
      expect(result.prompts.first[:template]).to eq("Fix the {{issue}} bug")
      expect(result.style_guides.size).to eq(1)
      expect(result.style_guides.first[:raw_content]).to eq("Use frozen string literals")
      expect(result.workflow_policies).to be_empty
    end

    it "maps Devin source data with workflow policies" do
      result = described_class.call(
        source_system: "devin",
        raw_data: {
          prompts: [ { name: "Implement Feature", template: "Build {{feature}}" } ],
          workflows: [
            { policy_key: "devin.auto_review", name: "Auto Review", rules: { "enabled" => true } }
          ]
        }
      )

      expect(result.source_system).to eq("devin")
      expect(result.prompts.size).to eq(1)
      expect(result.workflow_policies.size).to eq(1)
      expect(result.workflow_policies.first[:policy_key]).to eq("devin.auto_review")
    end

    it "maps internal agent workflows" do
      result = described_class.call(
        source_system: "internal_agent_workflows",
        raw_data: {
          prompts: [ { name: "Test Prompt", template: "Test {{var}}" } ],
          style_guides: [ { name: "Internal Guide", content: "Follow internal standards" } ],
          policies: [ { policy_key: "internal.review", name: "Internal Review", policy_type: "review" } ]
        }
      )

      expect(result.prompts.size).to eq(1)
      expect(result.style_guides.size).to eq(1)
      expect(result.workflow_policies.size).to eq(1)
      expect(result.workflow_policies.first[:policy_type]).to eq("execution")
    end

    it "raises for unknown source systems" do
      expect {
        described_class.call(source_system: "nonexistent_tool", raw_data: {})
      }.to raise_error(ArgumentError, /no mapper registered/)
    end

    it "generates a slug from name when slug is absent" do
      result = described_class.call(
        source_system: "github_copilot",
        raw_data: {
          prompts: [ { name: "My Custom Prompt", content: "Do the thing" } ]
        }
      )

      expect(result.prompts.first[:slug]).to eq("copilot.my.custom.prompt")
    end

    it "raises for unsupported workflow policy types during mapping" do
      expect {
        described_class.call(
          source_system: "factory",
          raw_data: {
            policies: [
              { policy_key: "factory.chaos", name: "Chaos", policy_type: "chaos" }
            ]
          }
        )
      }.to raise_error(ArgumentError, /unsupported policy_type for import: chaos/)
    end
  end
end
