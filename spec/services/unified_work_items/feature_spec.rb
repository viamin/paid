# frozen_string_literal: true

require "rails_helper"

RSpec.describe UnifiedWorkItems::Feature do
  let(:project) { instance_double(Project, flipper_id: "Project;unified-work-items", account: nil) }

  before do
    FeatureFlags.flipper[:unified_work_items].remove
  end

  # @spec UNIFIED-WORK-ITEMS-009
  it "is registered through FeatureFlags and defaults off" do
    definition = FeatureFlags.definition(:unified_work_items)

    expect(definition.owner).to eq("unified-work-items")
    expect { described_class.ensure_enabled!(project:) }
      .to raise_error(UnifiedWorkItems::FeatureDisabledError, /disabled/)
  end

  it "allows the explicit project enablement surface" do
    FeatureFlags.enable!(:unified_work_items, project:)

    expect { described_class.ensure_enabled!(project:) }.not_to raise_error
  end
end
