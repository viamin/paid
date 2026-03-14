# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::AssignVariant do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:prompt) { create(:prompt, account: account) }

    it "returns nil when no active test exists" do
      result = described_class.call(prompt: prompt, project: project)

      expect(result).to be_nil
    end

    it "returns a variant when an active test exists" do
      test = create(:ab_test, :running, :with_variants, prompt: prompt, account: account)

      result = described_class.call(prompt: prompt, project: project)

      expect(result).to be_an(AbTestVariant)
      expect(test.variants).to include(result)
    end

    it "respects traffic percentage" do
      create(:ab_test, :running, :with_variants, prompt: prompt, account: account, traffic_percentage: 0)

      result = described_class.call(prompt: prompt, project: project)

      expect(result).to be_nil
    end
  end
end
