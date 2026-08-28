# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunnersHelper, :no_db do
  describe "runner auth instruction removal" do
    # @spec RUNNERS-INDEX-006
    it "does not expose the removed auth setup helper API" do
      expect(described_class.const_defined?(:RUNNER_AUTH_INSTRUCTION_COPY, false)).to be(false)
      expect(helper).not_to respond_to(:runner_auth_instruction_blocks)
      expect(helper.private_methods).not_to include(:runner_auth_instruction_block)
    end
  end

  describe "#catalog_model_entries_by_service_type" do
    it "delegates to the batched ModelOptions lookup instead of looping per service type" do # @spec MODEL-POLICY-FORM-001
      expect(Runners::ModelOptions).to receive(:call_by_provider).with(
        runner_key: "opencode", api_providers: %w[anthropic openai], auth_type: "api_key"
      ).and_return("anthropic" => [], "openai" => [])

      result = helper.catalog_model_entries_by_service_type(
        runner_key: "opencode", service_types: %w[anthropic openai], auth_type: "api_key"
      )

      expect(result).to eq("anthropic" => [], "openai" => [])
    end
  end
end
