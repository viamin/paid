# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureFlags do
  # @spec LAYERED-VERIFY-012
  it "keeps the layered-verification add-on default-off" do
    project = create(:project)

    expect(described_class.enabled?(:layered_verification_add_on, project:)).to be(false)
  end
end
