# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-014
RSpec.describe FeatureIntents::DeliveryIntegration do
  let(:project) { create(:project) }

  it "fails closed until the confidence-delivery integration rollout is enabled" do
    expect(described_class.available_for?(project)).to be(false)
  end

  it "permits enrollment only when the integrated delivery rollout is enabled" do
    FeatureFlags.enable!(:confidence_driven_delivery, project: project)

    expect(described_class.available_for?(project)).to be(true)
  end
end
