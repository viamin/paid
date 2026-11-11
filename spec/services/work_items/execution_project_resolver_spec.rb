# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::ExecutionProjectResolver do
  let(:account) { create(:account) }
  let(:project_one) { create(:project, account:) }
  let(:project_two) { create(:project, account:) }
  let(:work_item) { create(:work_item, account:) }

  it "prefers the issue-level default over the mapping default" do
    # @spec UNIFIED-WORK-ITEMS-004
    mapping = create(:work_item_project_mapping, account:)
    mapping.work_item_project_mapping_targets.create!(project: project_one)
    mapping.work_item_project_mapping_targets.create!(project: project_two)
    mapping.update!(default_execution_project: project_one)
    work_item.work_item_assignments.create!(account:, project: project_one, provenance: "mapping", work_item_project_mapping: mapping)
    work_item.work_item_assignments.create!(account:, project: project_two, provenance: "mapping",
      work_item_project_mapping: mapping, default_execution: true)

    expect(described_class.call(work_item:)).to eq(project_two)
  end

  it "falls back to the mapping default when there is no issue-level default" do
    mapping = create(:work_item_project_mapping, account:, default_execution_project: nil)
    mapping.work_item_project_mapping_targets.create!(project: project_one)
    mapping.update!(default_execution_project: project_one)
    work_item.work_item_assignments.create!(account:, project: project_one, provenance: "mapping", work_item_project_mapping: mapping)

    expect(described_class.call(work_item:)).to eq(project_one)
  end

  it "returns nil with no default, leaving the candidates for the caller to prompt" do
    work_item.work_item_assignments.create!(account:, project: project_one, provenance: "manual")
    work_item.work_item_assignments.create!(account:, project: project_two, provenance: "manual")

    expect(described_class.call(work_item:)).to be_nil
    expect(described_class.new(work_item:).candidates).to contain_exactly(project_one, project_two)
  end
end
