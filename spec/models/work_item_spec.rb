# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItem do
  describe "#unassigned_first" do
    it "orders unassigned work items before assigned ones" do
      # @spec UNIFIED-WORK-ITEMS-004
      account = create(:account)
      project = create(:project, account:)
      assigned = create(:work_item, account:, title: "Assigned")
      create(:work_item_assignment, account:, work_item: assigned, project:)
      unassigned = create(:work_item, account:, title: "Unassigned")

      ordered = account.work_items.unassigned_first.to_a

      expect(ordered.first).to eq(unassigned)
      expect(ordered.last).to eq(assigned)
    end
  end

  describe "#locked_from_mapping?" do
    it "is true once any assignment is locked" do
      # @spec UNIFIED-WORK-ITEMS-004
      work_item = create(:work_item)
      project = create(:project, account: work_item.account)
      create(:work_item_assignment, account: work_item.account, work_item:, project:, locked: true)

      expect(work_item.locked_from_mapping?).to be true
    end

    it "is false with no locked assignment" do
      work_item = create(:work_item)
      project = create(:project, account: work_item.account)
      create(:work_item_assignment, account: work_item.account, work_item:, project:)

      expect(work_item.locked_from_mapping?).to be false
    end
  end

  describe "review flag" do
    it "flags and clears for review" do
      # @spec UNIFIED-WORK-ITEMS-004
      work_item = create(:work_item)

      expect { work_item.flag_for_review! }.to change(work_item, :needs_review?).from(false).to(true)
      expect { work_item.clear_review_flag! }.to change(work_item, :needs_review?).from(true).to(false)
    end
  end

  describe "#github?" do
    it "matches the GitHub provider regardless of case" do
      expect(create(:work_item, provider: "github")).to be_github
      expect(create(:work_item, provider: "GitHub")).to be_github
      expect(create(:work_item, provider: "linear")).not_to be_github
    end
  end

  describe "#default_execution_assignment" do
    it "returns the assignment marked as the default execution" do
      # @spec UNIFIED-WORK-ITEMS-004
      work_item = create(:work_item)
      other_project = create(:project, account: work_item.account)
      default_project = create(:project, account: work_item.account)
      create(:work_item_assignment, account: work_item.account, work_item:, project: other_project)
      default = create(:work_item_assignment, account: work_item.account, work_item:,
        project: default_project, default_execution: true)

      expect(work_item.default_execution_assignment).to eq(default)
    end

    it "is nil without a default execution assignment" do
      expect(create(:work_item).default_execution_assignment).to be_nil
    end
  end
end
