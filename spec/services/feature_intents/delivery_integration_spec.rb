# frozen_string_literal: true

require "rails_helper"

# @spec CONFIDENCE-DELIVERY-014
RSpec.describe FeatureIntents::DeliveryIntegration do
  let(:project) { create(:project) }

  it "fails closed until the confidence-delivery integration rollout is enabled" do
    expect(described_class.available_for?(project)).to be(false)
  end

  it "permits enrollment only when the integrated delivery rollout is enabled" do
    enable_review_enforcement
    FeatureFlags.enable!(:confidence_driven_delivery, project: project)

    expect(described_class.available_for?(project)).to be(true)
  end

  it "rejects enrollment when the rollout flag is enabled but review enforcement is absent" do
    FeatureFlags.enable!(:confidence_driven_delivery, project: project)

    expect(described_class.available_for?(project)).to be(false)
  end

  it "rejects enrollment while only half of the review enforcement pair is enabled" do
    enable_review_enforcement
    FeatureFlags.disable!(:intent_conformance_enforcement, project: project)
    FeatureFlags.enable!(:confidence_driven_delivery, project: project)

    expect(described_class.available_for?(project)).to be(false)
  end

  it "rejects enrollment on shadow review alone" do
    FeatureFlags.enable!(:intent_conformance_shadow_review, project: project)
    FeatureFlags.enable!(:confidence_driven_delivery, project: project)

    expect(described_class.available_for?(project)).to be(false)
  end

  def enable_review_enforcement
    FeatureFlags.enable!(:approved_intent_amendments, project: project)
    FeatureFlags.enable!(:intent_conformance_enforcement, project: project)
  end
end
