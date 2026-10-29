# frozen_string_literal: true

require "rails_helper"

RSpec.describe OpenrouterZdrCatalog do
  describe "#setup_state" do
    it "distinguishes loading, unavailable, stale, empty, and ready catalogs" do # @spec RUNNER-MODEL-OPTIONS-009
      catalog = described_class.current
      expect(catalog.setup_state).to eq("loading")

      catalog.update!(unavailable_at: Time.current)
      expect(catalog.setup_state).to eq("unavailable")

      catalog.update!(unavailable_at: nil, last_successful_at: 2.days.ago)
      expect(catalog.setup_state).to eq("stale")

      catalog.update!(last_successful_at: Time.current)
      expect(catalog.setup_state).to eq("empty")

      model = create(:llm_model, :inactive, model_id: "vendor/eligible")
      create(:openrouter_zdr_model, model_id: model.model_id)
      expect(catalog.setup_state).to eq("empty")

      model.update!(active: true)
      expect(catalog.setup_state).to eq("ready")
      expect(catalog).to be_ready_for_setup
    end
  end
end
