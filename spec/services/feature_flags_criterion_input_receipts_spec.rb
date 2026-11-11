# frozen_string_literal: true

require "rails_helper"

RSpec.describe FeatureFlags do
  # @spec LIVE-PREVIEW-013
  it "keeps criterion input receipts default-off" do
    project = create(:project)

    expect(described_class.enabled?(:criterion_input_receipts, project:)).to be(false)
  end
end
