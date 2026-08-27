# frozen_string_literal: true

require "rails_helper"

RSpec.describe LlmModel do
  describe "validations" do
    subject { build(:llm_model) }

    it { is_expected.to validate_presence_of(:model_id) }
    it { is_expected.to validate_uniqueness_of(:model_id) }
    it { is_expected.to validate_presence_of(:display_name) }
    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:category) }
    it { is_expected.to validate_inclusion_of(:category).in_array(described_class::CATEGORIES) }
    it { is_expected.to validate_inclusion_of(:pricing_tier).in_array(described_class::PRICING_TIERS) }
    it { is_expected.to validate_inclusion_of(:catalog_source).in_array(described_class::CATALOG_SOURCES) }

    it "permits a nil tier" do
      expect(build(:llm_model, tier: nil)).to be_valid
    end

    it "permits a nil data_training_risk" do
      expect(build(:llm_model, data_training_risk: nil)).to be_valid
    end

    it "rejects an unknown data_training_risk" do
      model = build(:llm_model, data_training_risk: "always")

      expect(model).not_to be_valid
      expect(model.errors[:data_training_risk]).to be_present
    end

    it "accepts each known data_training_risk" do
      LlmModel::DATA_TRAINING_RISKS.each do |risk|
        expect(build(:llm_model, data_training_risk: risk)).to be_valid
      end
    end

    it "rejects an unknown tier" do
      model = build(:llm_model, tier: "ultra")
      expect(model).not_to be_valid
      expect(model.errors[:tier]).to be_present
    end

    it "accepts each known tier" do
      LlmModel::TIERS.each do |tier|
        expect(build(:llm_model, tier: tier)).to be_valid
      end
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:free_variant_of).class_name("LlmModel").optional }
    it { is_expected.to have_many(:model_selections) }
  end

  describe "scopes" do
    describe ".free" do
      it "returns only free models" do
        free_model = create(:llm_model, pricing_tier: "free")
        create(:llm_model, pricing_tier: "paid")

        expect(described_class.free).to eq([ free_model ])
      end
    end

    describe ".paid" do
      it "returns only paid models" do
        paid_model = create(:llm_model, pricing_tier: "paid")
        create(:llm_model, pricing_tier: "free")

        expect(described_class.paid).to eq([ paid_model ])
      end
    end

    describe ".by_pricing_tier" do
      it "filters by pricing tier" do
        freemium = create(:llm_model, pricing_tier: "freemium")
        create(:llm_model, pricing_tier: "paid")

        expect(described_class.by_pricing_tier("freemium")).to eq([ freemium ])
      end
    end

    describe ".active" do
      it "returns only active models" do
        active = create(:llm_model, active: true)
        create(:llm_model, :inactive)

        expect(described_class.active).to eq([ active ])
      end
    end

    describe ".by_provider" do
      it "filters by provider" do
        anthropic = create(:llm_model, provider: "anthropic")
        create(:llm_model, :openai)

        expect(described_class.by_provider("anthropic")).to eq([ anthropic ])
      end
    end

    describe ".by_tier" do
      it "filters by tier" do
        high = create(:llm_model, tier: "high")
        create(:llm_model, tier: "low")

        expect(described_class.by_tier("high")).to eq([ high ])
      end
    end

    describe ".by_category" do
      it "filters by category" do
        coding = create(:llm_model, category: "coding")
        create(:llm_model, :planning)

        expect(described_class.by_category("coding")).to eq([ coding ])
      end
    end
  end

  describe ".dropdown_options_for" do
    # @spec DIRECT-OUTBOUND-CATALOG-005
    it "returns active rows for the given provider, ordered by display name" do
      create(:llm_model, provider: "deepseek", display_name: "Zeta", active: true)
      alpha = create(:llm_model, provider: "deepseek", display_name: "Alpha", active: true)
      create(:llm_model, provider: "deepseek", display_name: "Inactive", active: false)
      create(:llm_model, :openai, display_name: "Other Provider")

      options = described_class.dropdown_options_for("deepseek")

      expect(options.map(&:display_name)).to eq([ "Alpha", "Zeta" ])
      expect(options).to include(alpha)
    end

    # @spec DIRECT-OUTBOUND-CATALOG-005
    it "returns an empty relation when the provider has no catalog rows (degradation contract)" do
      expect(described_class.dropdown_options_for("no-such-provider")).to be_empty
    end
  end

  describe "#estimated_cost" do
    it "calculates cost in cents from token counts" do
      model = build(:llm_model, input_cost_per_million: 3.0, output_cost_per_million: 15.0)

      cost = model.estimated_cost(1_000_000, 100_000)

      # Input: 3.0 * 1 = 3.0, Output: 15.0 * 0.1 = 1.5, Total: 4.5 => 450 cents
      expect(cost).to eq(450)
    end
  end

  describe "#free?" do
    it "returns true when the pricing tier is free" do
      expect(build(:llm_model, pricing_tier: "free")).to be_free
    end

    it "returns false for non-free pricing tiers" do
      expect(build(:llm_model, pricing_tier: "paid")).not_to be_free
    end
  end

  describe ".default_for_task" do
    it "returns highest capability model for the given category" do
      create(:llm_model, category: "coding", capability_score: 7.0)
      best = create(:llm_model, category: "coding", capability_score: 9.0)

      expect(described_class.default_for_task("coding")).to eq(best)
    end

    it "falls back to any active model when category has none" do
      model = create(:llm_model, category: "coding", capability_score: 8.0)

      expect(described_class.default_for_task("review")).to eq(model)
    end
  end

  describe ".upsert_manual_catalog_entry" do
    it "creates a manual catalog row when the model id is unknown (#2669)" do
      expect {
        described_class.upsert_manual_catalog_entry(model_id: "MiniMax-M3", provider: "minimax")
      }.to change(described_class.where(catalog_source: "manual"), :count).by(1)

      model = described_class.find_by(model_id: "MiniMax-M3")
      expect(model.provider).to eq("minimax")
      expect(model.catalog_source).to eq("manual")
      expect(model.active).to be(true)
    end

    it "returns the existing row when the model id is already present" do
      existing = create(:llm_model, model_id: "MiniMax-M3", provider: "minimax", catalog_source: "seeded")

      expect {
        result = described_class.upsert_manual_catalog_entry(model_id: "MiniMax-M3", provider: "minimax")
        expect(result).to eq(existing)
      }.not_to change(described_class, :count)
    end

    it "is idempotent under concurrent callers via the model_id unique index" do
      threads = Array.new(3) do
        Thread.new { described_class.upsert_manual_catalog_entry(model_id: "MiniMax-M3", provider: "minimax") }
      end

      expect { threads.each(&:join) }.not_to raise_error
      expect(described_class.where(model_id: "MiniMax-M3").count).to eq(1)
    end
  end
end
