# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Lifecycle::ApplyPaidChange do
  let(:project) { create(:project) }
  let(:account) { project.account }
  let(:token) { create(:linear_token, account:) }
  let(:configuration) { create(:tracker_configuration, :linear, configurable: account, linear_token: token) }
  let(:work_item) { create(:work_item, account:, tracker_configuration: configuration, native_state: "Todo") }

  before do
    create(:work_item_lifecycle_mapping, account:, native_state: "In Progress", paid_state: "in_progress")
    work_item.work_item_assignments.create!(account:, project:, provenance: "manual")
  end

  def stub_update
    stub_request(:post, "https://api.linear.app/graphql").to_return(status: 200,
      body: JSON.generate(data: { issueUpdate: { success: true, issue: { id: work_item.external_id } } }))
  end

  it "is a no-op loop-safe when the Paid state has not changed" do
    # @spec UNIFIED-WORK-ITEMS-006
    work_item.update!(paid_lifecycle_state: "in_progress")

    result = described_class.call(work_item:, paid_state: "in_progress")

    expect(result.status).to eq(:unchanged)
  end

  it "applies the Paid state and pushes the mapped native state to the provider" do
    stub_update

    result = described_class.call(work_item:, paid_state: "in_progress")

    expect(result.status).to eq(:applied)
    expect(work_item.reload).to have_attributes(paid_lifecycle_state: "in_progress", lifecycle_sync_source: "paid")
    expect(a_request(:post, "https://api.linear.app/graphql")).to have_been_made
  end

  it "skips an agent-run-driven write when the project disables agent-run lifecycle sync" do
    # @spec UNIFIED-WORK-ITEMS-006
    project.update!(agent_run_lifecycle_sync_enabled: false)

    result = described_class.call(work_item:, paid_state: "in_progress", agent_run: build(:agent_run))

    expect(result.status).to eq(:agent_run_sync_disabled)
    expect(work_item.reload.paid_lifecycle_state).to be_nil
    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
  end

  it "flags a simultaneous conflicting change for human review instead of silently overwriting it" do
    work_item.update!(native_state: "Done", lifecycle_sync_source: "provider")

    result = described_class.call(work_item:, paid_state: "in_progress")

    expect(result.status).to eq(:conflict)
    expect(result.conflict).to have_attributes(observed_native_state: "Done", requested_native_state: "In Progress")
    expect(work_item.reload.paid_lifecycle_state).to be_nil
    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
  end
end
