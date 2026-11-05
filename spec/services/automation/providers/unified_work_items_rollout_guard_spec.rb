# frozen_string_literal: true

require "rails_helper"

# @spec UNIFIED-WORK-ITEMS-009
RSpec.describe Automation::Providers::UnifiedWorkItemsRolloutGuard do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  it "is default-off, project-scoped, and honors account overrides" do
    expect(described_class.enabled?(project)).to be(false)

    FeatureFlags.enable!(:unified_work_items, project:)
    expect(described_class.enabled?(project)).to be(true)

    create(:tenant_setting, account:, features: { "unified_work_items" => false })
    expect(described_class.enabled?(project)).to be(false)
  end
end
