# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::SetDefaultExecutionProject do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:other_project) { create(:project, account:) }
  let(:work_item) { create(:work_item, account:) }

  it "sets exactly one default execution project among the assigned projects" do
    # @spec UNIFIED-WORK-ITEMS-004
    work_item.work_item_assignments.create!(account:, project:, provenance: "manual")
    assignment_two = work_item.work_item_assignments.create!(account:, project: other_project, provenance: "manual")

    described_class.call(work_item:, project:)
    described_class.call(work_item:, project: other_project)

    expect(assignment_two.reload.default_execution).to be true
    expect(work_item.work_item_assignments.where(project:).first.default_execution).to be false
  end

  it "raises when the project is not assigned to the work item" do
    expect { described_class.call(work_item:, project:) }.to raise_error(described_class::NotAssignedError)
  end
end
