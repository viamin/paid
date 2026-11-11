# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Overrides::Replace do
  let(:account) { create(:account) }
  let(:mapped_project) { create(:project, account:) }
  let(:replacement_project) { create(:project, account:) }
  let(:actor) { create(:user, account:) }

  before do
    FeatureFlags.enable!(:unified_work_items, project: mapped_project)
    FeatureFlags.enable!(:unified_work_items, project: replacement_project)
  end

  it "removes the mapping-driven assignment entirely and replaces it with the explicit choice" do
    # @spec UNIFIED-WORK-ITEMS-004
    work_item = create(:work_item, account:)
    work_item.work_item_assignments.create!(account:, project: mapped_project, provenance: "mapping")

    described_class.call(work_item:, projects: [ replacement_project ], actor:, note: "wrong project")

    work_item.reload
    expect(work_item.projects).to contain_exactly(replacement_project)
    expect(work_item.work_item_assignments.first).to have_attributes(provenance: "manual", locked: true)
    expect(work_item.work_item_assignment_overrides.last).to have_attributes(mode: "replaced", note: "wrong project")
  end

  it "rejects a disabled replacement target without changing existing assignments" do
    # @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-009
    disabled_project = create(:project, account:)
    work_item = create(:work_item, account:)
    work_item.work_item_assignments.create!(account:, project: mapped_project, provenance: "mapping")

    expect { described_class.call(work_item:, projects: [ disabled_project ], actor:) }
      .to raise_error(ArgumentError, "every target project must have unified work items enabled")
    expect(work_item.reload.projects).to contain_exactly(mapped_project)
    expect(work_item.work_item_assignment_overrides).to be_empty
  end
end
