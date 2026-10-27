# frozen_string_literal: true

require "rails_helper"

RSpec.describe ModelsSyncJob do
  describe "#perform" do
    # @spec MODEL-AVAILABILITY-004 MODEL-AVAILABILITY-008
    it "prepares the registry before publishing the catalog and reconciling availability" do
      call_order = []
      prepared_registry = instance_double(Models::RegistryModels)
      allow(Models::RegistryModels).to receive(:fetch) { call_order << :fetch; prepared_registry }
      allow(Models::CatalogSnapshot).to receive(:refresh).and_yield
      allow(Models::SeedKnownModels).to receive(:call) do |registry_models:|
        expect(registry_models).to eq(prepared_registry)
        call_order << :seed
        5
      end
      allow(Models::ReconcileAvailability).to receive(:refresh_known_contexts!) { call_order << :reconcile; { "codex:api_key" => 0 } }

      described_class.new.perform

      expect(call_order).to eq(%i[fetch seed reconcile])
      expect(Models::CatalogSnapshot).to have_received(:refresh).once
    end
  end
end
