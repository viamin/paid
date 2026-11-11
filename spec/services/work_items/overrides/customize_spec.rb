# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Overrides::Customize do
  let(:account) { create(:account) }
  let(:mapped_project) { create(:project, account:) }
  let(:extra_project) { create(:project, account:) }
  let(:actor) { create(:user, account:) }

  before do
    FeatureFlags.enable!(:unified_work_items, project: mapped_project)
    FeatureFlags.enable!(:unified_work_items, project: extra_project)
  end

  it "adds a project without removing the mapping-driven assignment, then locks and records provenance" do
    # @spec UNIFIED-WORK-ITEMS-004
    work_item = create(:work_item, account:)
    work_item.work_item_assignments.create!(account:, project: mapped_project, provenance: "mapping")
    work_item.flag_for_review!

    described_class.call(work_item:, projects: [ extra_project ], actor:)

    work_item.reload
    expect(work_item.projects).to contain_exactly(mapped_project, extra_project)
    expect(work_item.work_item_assignments).to all(have_attributes(locked: true))
    expect(work_item.work_item_assignment_overrides.last).to have_attributes(mode: "customized", actor:)
    expect(work_item.needs_review?).to be false
  end
end
