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
end
