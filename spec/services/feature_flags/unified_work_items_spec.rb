# frozen_string_literal: true

require "rails_helper"

# @spec UNIFIED-WORK-ITEMS-009
RSpec.describe FeatureFlags do
  describe ".enabled?" do
    it "keeps unified work items default-off and supports project enablement" do
      project = create(:project)

      expect(described_class.enabled?(:unified_work_items, project:)).to be(false)

      described_class.enable!(:unified_work_items, project:)

      expect(described_class.enabled?(:unified_work_items, project:)).to be(true)
      expect(described_class.enabled?(:unified_work_items)).to be(false)
    end
  end
end
