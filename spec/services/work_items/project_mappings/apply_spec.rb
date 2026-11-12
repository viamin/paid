# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::ProjectMappings::Apply do
  let(:account) { create(:account) }
  let(:target) { create(:project, account:) }

  before { FeatureFlags.enable!(:unified_work_items, project: target) }

  def call(mode: "current_and_future", confirmed: true, targets: [ target ], default_execution_project: nil)
    described_class.call(account:, provider: "linear", native_project_id: "linear-1",
      native_project_name: "Roadmap", target_projects: targets, assignment_mode: mode,
      default_execution_project:, confirmed:)
  end

  it "previews without writing anything when not confirmed" do
    # @spec UNIFIED-WORK-ITEMS-004
    create(:work_item, account:, native_project_id: "linear-1")

    expect { call(confirmed: false) }.not_to change(WorkItemAssignment, :count)
    expect(WorkItemProjectMapping.count).to eq(0)
  end

  it "assigns matching work items when the mode is current_and_future" do
    item = create(:work_item, account:, native_project_id: "linear-1")

    result = call

    expect(item.reload.projects).to contain_exactly(target)
    expect(item.work_item_assignments.first.provenance).to eq("mapping")
    expect(result.to_assign).to include(item)
  end

  it "does not touch existing tickets when the mode is future_only" do
    item = create(:work_item, account:, native_project_id: "linear-1")

    call(mode: "future_only")

    expect(item.reload.projects).to be_empty
  end

  it "never assigns anything when the mode is none" do
    item = create(:work_item, account:, native_project_id: "linear-1")

    call(mode: "none")

    expect(item.reload.projects).to be_empty
  end

  it "skips a locked work item and flags it for review instead of silently reassigning it" do
    item = create(:work_item, account:, native_project_id: "linear-1")
    other_project = create(:project, account:)
    FeatureFlags.enable!(:unified_work_items, project: other_project)
    WorkItems::Overrides::Replace.call(work_item: item, projects: [ other_project ])

    call

    item.reload
    expect(item.projects).to contain_exactly(other_project)
    expect(item.needs_review?).to be true
  end

  it "removes a mapping-provenance assignment for a project no longer targeted" do
    item = create(:work_item, account:, native_project_id: "linear-1")
    call

    other_target = create(:project, account:)
    FeatureFlags.enable!(:unified_work_items, project: other_target)
    call(targets: [ other_target ])

    item.reload
    expect(item.projects).to contain_exactly(other_target)
  end

  it "sets the mapping-level default execution project among the targets" do
    mapping_result = call(default_execution_project: target)

    expect(mapping_result.mapping.default_execution_project).to eq(target)
  end

  it "rejects a target project where the rollout guard is disabled" do
    # @spec UNIFIED-WORK-ITEMS-009
    disabled_project = create(:project, account:)

    expect { call(targets: [ disabled_project ]) }.to raise_error(ArgumentError)
  end
end
