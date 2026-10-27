# frozen_string_literal: true

require "rails_helper"

RSpec.describe ModelsSyncJob do
  describe "#perform" do
    # @spec MODEL-AVAILABILITY-004
    it "seeds the catalog and then reconciles availability for the standard runner/auth contexts" do
      call_order = []
      allow(Models::CatalogSnapshot).to receive(:refresh).and_yield
      allow(Models::SeedKnownModels).to receive(:call) { call_order << :seed; 5 }
      allow(Models::ReconcileAvailability).to receive(:refresh_known_contexts!) { call_order << :reconcile; { "codex:api_key" => 0 } }

      described_class.new.perform

      expect(call_order).to eq(%i[seed reconcile])
      expect(Models::CatalogSnapshot).to have_received(:refresh).once
    end
  end
end
