# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Lifecycle::ApplyProviderChange do
  let(:account) { create(:account) }
  let(:work_item) { create(:work_item, account:, native_state: "Todo") }

  before { create(:work_item_lifecycle_mapping, account:, native_state: "In Progress", paid_state: "in_progress") }

  it "is a no-op loop-safe when the native state has not changed" do
    # @spec UNIFIED-WORK-ITEMS-006
    result = described_class.call(work_item:, native_state: "Todo")

    expect(result.status).to eq(:unchanged)
  end

  it "applies the mapped Paid state and records the provider as the sync source" do
    result = described_class.call(work_item:, native_state: "In Progress")

    expect(result.status).to eq(:applied)
    expect(work_item.reload).to have_attributes(native_state: "In Progress", paid_lifecycle_state: "in_progress",
      lifecycle_sync_source: "provider")
  end

  it "uses the initiating project lifecycle mapping when assignments have different mappings" do
    first_project = create(:project, account:)
    initiating_project = create(:project, account:)
    work_item.work_item_assignments.create!(account:, project: first_project, provenance: "manual")
    work_item.work_item_assignments.create!(account:, project: initiating_project, provenance: "manual")
    create(:work_item_lifecycle_mapping, account:, project: first_project,
      native_state: "In Progress", paid_state: "first_project")
    create(:work_item_lifecycle_mapping, account:, project: initiating_project,
      native_state: "In Progress", paid_state: "initiating_project")

    result = described_class.call(work_item:, native_state: "In Progress", project: initiating_project)

    expect(result.status).to eq(:applied)
    expect(work_item.reload.paid_lifecycle_state).to eq("initiating_project")
  end

  it "reports unsupported without claiming success when no mapping covers the native state" do
    result = described_class.call(work_item:, native_state: "Weird State")

    expect(result.status).to eq(:unsupported)
    expect(work_item.reload.native_state).to eq("Weird State")
  end

  it "flags a simultaneous conflicting change for human review instead of silently overwriting it" do
    work_item.update!(paid_lifecycle_state: "blocked", lifecycle_sync_source: "paid")

    result = described_class.call(work_item:, native_state: "In Progress")

    expect(result.status).to eq(:conflict)
    expect(result.conflict).to have_attributes(observed_paid_state: "blocked", requested_paid_state: "in_progress")
    expect(work_item.reload.native_state).to eq("Todo")
  end
end
