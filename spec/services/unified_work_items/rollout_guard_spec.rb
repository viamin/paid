# frozen_string_literal: true

require "rails_helper"

# @spec UNIFIED-WORK-ITEMS-009
RSpec.describe UnifiedWorkItems::RolloutGuard do
  it "raises before any unified runtime entry point can use a disabled project" do
    project = create(:project)

    expect {
      described_class.require_enabled!(project)
    }.to raise_error(described_class::FeatureDisabledError, /not enabled/)
  end
end
