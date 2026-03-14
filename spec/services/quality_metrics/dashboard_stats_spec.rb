# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::DashboardStats do
  describe ".call" do
    let(:account) { create(:account) }

    it "returns overview stats" do
      result = described_class.call(account: account)

      expect(result[:overview]).to include(
        total_metrics: 0,
        scored_metrics: 0,
        avg_quality_score: 0.0
      )
    end

    it "returns score distribution" do
      result = described_class.call(account: account)

      expect(result[:score_distribution]).to be_a(Hash)
      expect(result[:score_distribution].keys).to include("0.0-0.2", "0.8-1.0")
    end

    it "returns empty arrays for by_prompt and by_model" do
      result = described_class.call(account: account)

      expect(result[:by_prompt]).to eq([])
      expect(result[:by_model]).to eq([])
    end
  end
end
