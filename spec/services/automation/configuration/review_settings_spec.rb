# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Configuration::ReviewSettings do
  describe ".from_hash" do
    it "returns a fully-populated object even when the input is empty" do
      settings = described_class.from_hash({})

      expect(settings.enabled?).to be false
      expect(settings.wait_for_reviews?).to be true
      expect(settings.address_all_bot_reviews?).to be false
      expect(settings.enabled_method_names).to eq([])
      expect(settings.methods.keys).to match_array(Automation::Configuration::ReviewMethod::NAMES)
    end

    it "builds a ReviewMethod for every known method even when absent" do
      settings = described_class.from_hash(
        "enabled" => true,
        "methods" => {
          "paid_agent" => { "enabled" => true }
        }
      )

      expect(settings.method_for(:paid_agent).enabled?).to be true
      expect(settings.method_for(:copilot).enabled?).to be false
    end

    it "treats wait_for_reviews as true by default and respects explicit false" do
      explicit_false = described_class.from_hash("wait_for_reviews" => false)
      explicit_true  = described_class.from_hash("wait_for_reviews" => true)

      expect(explicit_false.wait_for_reviews?).to be false
      expect(explicit_true.wait_for_reviews?).to be true
    end
  end

  describe "#enabled_method_names" do
    it "returns enabled methods in canonical ReviewMethod::NAMES order" do
      settings = described_class.from_hash(
        "methods" => {
          "manual" => { "enabled" => true },
          "copilot" => { "enabled" => true },
          "paid_agent" => { "enabled" => true }
        }
      )

      expect(settings.enabled_method_names).to eq(%i[copilot paid_agent manual])
    end
  end

  describe ".from_project" do
    it "delegates to Project#effective_review_settings" do
      project = build(:project, review_settings: { "enabled" => true })
      settings = described_class.from_project(project)

      expect(settings.enabled?).to be true
    end
  end
end
