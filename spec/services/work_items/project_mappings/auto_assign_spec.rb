# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::ProjectMappings::AutoAssign do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  before { FeatureFlags.enable!(:unified_work_items, project:) }

  it "assigns a ticket first imported after a future-only mapping was created" do
    # @spec UNIFIED-WORK-ITEMS-004
    mapping = create(:work_item_project_mapping, account:, provider: "linear", native_project_id: "linear-1",
      assignment_mode: "future_only")
    mapping.work_item_project_mapping_targets.create!(project:)
    work_item = travel_to(1.second.from_now) do
      create(:work_item, account:, provider: "linear", native_project_id: "linear-1")
    end

    described_class.call(work_item:)

    expect(work_item.reload.projects).to contain_exactly(project)
    expect(work_item.work_item_assignments.first).to have_attributes(provenance: "mapping", work_item_project_mapping: mapping)
  end

  it "does not assign a ticket that existed before a future-only mapping" do
    # @spec UNIFIED-WORK-ITEMS-004
    work_item = create(:work_item, account:, provider: "linear", native_project_id: "linear-1")
    mapping = travel_to(1.second.from_now) do
      create(:work_item_project_mapping, account:, provider: "linear", native_project_id: "linear-1",
        assignment_mode: "future_only")
    end
    mapping.work_item_project_mapping_targets.create!(project:)

    described_class.call(work_item:)

    expect(work_item.reload.projects).to be_empty
  end
end
