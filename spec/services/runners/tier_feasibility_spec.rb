# frozen_string_literal: true

require "rails_helper"

RSpec.describe Runners::TierFeasibility do
  subject(:feasibility) { described_class.new }

  let(:user) { create(:user) }

  # Materialized eagerly: creating the settings row seeds the default runners.
  before { user.settings }

  describe "#infeasible_tiers" do
    before { allow(Runners::DefaultTierModelIds).to receive(:call).and_return({}) }

    # @spec AUTO-PICK-QUEUE-011
    it "reports every catalog tier no runner of the owner can satisfy" do
      user.runners.find_by!(runner_key: "claude").update!(tier_models: {})

      expect(feasibility.infeasible_tiers(user)).to eq(LlmModel::TIERS)
    end

    # @spec AUTO-PICK-QUEUE-011
    it "reports only the tiers the owner's runner configuration cannot satisfy" do
      user.runners.find_by!(runner_key: "claude")
        .update!(tier_models: { "low" => { "model_id" => "claude-haiku", "provider_id" => 1 } })

      expect(feasibility.infeasible_tiers(user)).to eq(%w[mid high])
    end

    it "reports nothing for an ownerless project, leaving the dispatch-time filter as the final gate" do
      expect(feasibility.infeasible_tiers(nil)).to eq([])
    end

    it "resolves each owner once per instance, however many times it is asked" do
      other_user = create(:user)
      other_user.settings
      per_resolution = count_queries { described_class.new.infeasible_tiers(user) }

      queries = capture_queries do
        3.times { feasibility.infeasible_tiers(user) }
        2.times { feasibility.infeasible_tiers(other_user) }
      end

      expect(per_resolution).to be_positive
      expect(queries.size).to eq(per_resolution * 2)
    end

    it "re-reads runner configuration on the next pass instead of caching it across passes" do
      expect(feasibility.infeasible_tiers(user)).to eq(LlmModel::TIERS)

      user.runners.find_by!(runner_key: "claude").update!(
        tier_models: LlmModel::TIERS.index_with { |tier| { "model_id" => "claude-#{tier}", "provider_id" => 1 } }
      )

      expect(described_class.new.infeasible_tiers(user)).to eq([])
    end
  end
end
