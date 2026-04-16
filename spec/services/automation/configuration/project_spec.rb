# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Configuration::Project do
  describe ".from" do
    it "aggregates every sub-config from a project record" do
      project = build(:project,
        auto_pick_enabled: true,
        auto_merge_enabled: true,
        auto_fix_merge_conflicts: true,
        merge_method: "squash",
        review_settings: {
          "enabled" => true,
          "methods" => { "paid_agent" => { "enabled" => true } }
        })

      config = described_class.from(project)

      expect(config.auto_pick.enabled?).to be true
      expect(config.auto_merge.enabled?).to be true
      expect(config.auto_merge.fix_merge_conflicts?).to be true
      expect(config.auto_merge.merge_method).to eq("squash")
      expect(config.auto_review.enabled?).to be true
      expect(config.review_settings.method_enabled?(:paid_agent)).to be true
    end

    it "defaults auto_continue to enabled when auto_scan_prs is on" do
      project = build(:project)
      expect(described_class.from(project).auto_continue.enabled?).to be true
    end
  end

  describe "value-object semantics" do
    it "is equal to another Project built from the same project record" do
      project = build(:project)
      first = described_class.from(project)
      second = described_class.from(project)

      expect(first).to eq(second)
    end
  end
end
