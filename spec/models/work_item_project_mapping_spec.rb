# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItemProjectMapping do
  describe "validations" do
    it "is valid with current_and_future, future_only, or none" do
      # @spec UNIFIED-WORK-ITEMS-004
      described_class::ASSIGNMENT_MODES.each do |mode|
        mapping = build(:work_item_project_mapping, assignment_mode: mode)
        expect(mapping).to be_valid, "expected #{mode} to be valid"
      end
    end

    it "rejects an unknown assignment mode" do
      mapping = build(:work_item_project_mapping, assignment_mode: "whenever")

      expect(mapping).not_to be_valid
    end

    it "rejects a duplicate native project for the same account and provider" do
      account = create(:account)
      create(:work_item_project_mapping, account:, native_project_id: "linear-1")
      duplicate = build(:work_item_project_mapping, account:, native_project_id: "linear-1")

      expect(duplicate).not_to be_valid
    end

    it "requires the default execution project to be one of the mapping's targets" do
      account = create(:account)
      mapping = create(:work_item_project_mapping, account:)
      target = create(:project, account:)
      mapping.work_item_project_mapping_targets.create!(project: target)
      other_project = create(:project, account:)

      mapping.default_execution_project = other_project

      expect(mapping).not_to be_valid
      expect(mapping.errors[:default_execution_project]).to be_present
    end
  end
end
