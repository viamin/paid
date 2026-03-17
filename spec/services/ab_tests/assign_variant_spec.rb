# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::AssignVariant do
  describe ".call" do
    let(:prompt) { create(:prompt, :global, :with_version) }

    it "returns nil when no active test exists" do
      result = described_class.call(prompt: prompt)

      expect(result).to be_nil
    end

    it "returns a variant when an active test exists" do
      test = create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)
      create(:ab_test_variant, ab_test: test, is_control: true)
      create(:ab_test_variant, ab_test: test)

      result = described_class.call(prompt: prompt)

      expect(result).to be_an(AbTestVariant)
      expect(test.ab_test_variants).to include(result)
    end

    it "prevents double-assignment for the same agent run" do
      test = create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)
      control = create(:ab_test_variant, ab_test: test, is_control: true)
      create(:ab_test_variant, ab_test: test)
      agent_run = create(:agent_run)

      first_result = described_class.call(prompt: prompt, agent_run: agent_run)
      second_result = described_class.call(prompt: prompt, agent_run: agent_run)

      expect(first_result).to eq(second_result)
    end
  end
end
