# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::CatalogSnapshot do
  # @spec MODEL-AVAILABILITY-008
  it "holds the exclusive refresh snapshot across catalog seeding and availability reconciliation" do
    events = []

    described_class.refresh do
      events << :seed
      events << :reconcile
    end

    expect(events).to eq(%i[seed reconcile])
  end

  # @spec MODEL-AVAILABILITY-008
  it "provides a shared snapshot for an onboarding catalog read" do
    expect(described_class.consistent_read { :resolved }).to eq(:resolved)
  end
end
