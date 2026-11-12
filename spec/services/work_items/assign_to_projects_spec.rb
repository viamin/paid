# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::AssignToProjects do
  let(:account) { create(:account) }
  let(:project_one) { create(:project, account:) }
  let(:project_two) { create(:project, account:) }
  let(:work_item) { create(:work_item, account:) }

  before do
    FeatureFlags.enable!(:unified_work_items, project: project_one)
    FeatureFlags.enable!(:unified_work_items, project: project_two)
  end

  it "bulk-assigns multiple work items to multiple projects as manual provenance" do
    # @spec UNIFIED-WORK-ITEMS-004
    other_item = create(:work_item, account:)

    expect do
      described_class.call(work_items: [ work_item, other_item ], projects: [ project_one, project_two ])
    end.to change(WorkItemAssignment, :count).by(4)

    expect(work_item.work_item_assignments.pluck(:project_id)).to contain_exactly(project_one.id, project_two.id)
    expect(work_item.work_item_assignments.first.provenance).to eq("manual")
  end

  it "is idempotent for an already-assigned pair" do
    described_class.call(work_items: [ work_item ], projects: [ project_one ])

    expect { described_class.call(work_items: [ work_item ], projects: [ project_one ]) }
      .not_to change(WorkItemAssignment, :count)
  end

  it "skips projects where the rollout guard is disabled" do
    # @spec UNIFIED-WORK-ITEMS-009
    disabled_project = create(:project, account:)

    described_class.call(work_items: [ work_item ], projects: [ disabled_project ])

    expect(work_item.work_item_assignments).to be_empty
  end
end
