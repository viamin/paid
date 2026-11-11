# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Lifecycle::ApplyPaidChange do
  let(:project) { create(:project) }
  let(:account) { project.account }
  let(:token) { create(:linear_token, account:) }
  let(:configuration) { create(:tracker_configuration, :linear, configurable: account, linear_token: token) }
  let(:work_item) { create(:work_item, account:, tracker_configuration: configuration, native_state: "Todo") }

  before do
    create(:tenant_setting, account:, features: { "unified_work_items" => true })
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

  it "keeps the local lifecycle state retryable when the provider write fails" do
    # @spec UNIFIED-WORK-ITEMS-006
    stub_request(:post, "https://api.linear.app/graphql").to_return(status: 500, body: "unavailable")

    expect { described_class.call(work_item:, paid_state: "in_progress") }
      .to raise_error(IssueTrackers::Adapters::Linear::ResponseError)
    expect(work_item.reload.paid_lifecycle_state).to be_nil

    stub_update

    result = described_class.call(work_item:, paid_state: "in_progress")

    expect(result.status).to eq(:applied)
    expect(work_item.reload).to have_attributes(paid_lifecycle_state: "in_progress", lifecycle_sync_source: "paid")
  end

  it "uses the initiating project lifecycle mapping when assignments have different mappings" do
    other_project = create(:project, account:)
    work_item.work_item_assignments.create!(account:, project: other_project, provenance: "manual")
    create(:work_item_lifecycle_mapping, account:, project:,
      native_state: "first-project-state", paid_state: "in_progress")
    create(:work_item_lifecycle_mapping, account:, project: other_project,
      native_state: "initiating-project-state", paid_state: "in_progress")
    stub_update

    result = described_class.call(work_item:, paid_state: "in_progress", project: other_project)

    expect(result.status).to eq(:applied)
    expect(a_request(:post, "https://api.linear.app/graphql").with { |request|
      JSON.parse(request.body).dig("variables", "input", "stateId") == "initiating-project-state"
    }).to have_been_made
  end

  it "skips an agent-run-driven write when the project disables agent-run lifecycle sync" do
    # @spec UNIFIED-WORK-ITEMS-006
    project.update!(agent_run_lifecycle_sync_enabled: false)

    result = described_class.call(work_item:, paid_state: "in_progress", project:, agent_run: build(:agent_run))

    expect(result.status).to eq(:agent_run_sync_disabled)
    expect(work_item.reload.paid_lifecycle_state).to be_nil
    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
  end

  it "flags a simultaneous conflicting change for human review instead of silently overwriting it" do
    command = described_class.new(work_item:, paid_state: "in_progress")
    work_item.update!(native_state: "Done", lifecycle_sync_source: "provider", lifecycle_synced_at: Time.current)

    result = command.call

    expect(result.status).to eq(:conflict)
    expect(result.conflict).to have_attributes(observed_native_state: "Done", requested_native_state: "In Progress")
    expect(work_item.reload.paid_lifecycle_state).to be_nil
    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
  end

  it "applies a sequential Paid transition after observing a provider transition" do
    # @spec UNIFIED-WORK-ITEMS-006
    work_item.update!(native_state: "Todo", lifecycle_sync_source: "provider", lifecycle_synced_at: Time.current)
    stub_update

    result = described_class.call(work_item:, paid_state: "in_progress")

    expect(result.status).to eq(:applied)
    expect(work_item.reload.paid_lifecycle_state).to eq("in_progress")
  end

  it "does not write locally or to the provider while unified work items are disabled" do
    # @spec UNIFIED-WORK-ITEMS-009
    account.tenant_setting.update!(features: { "unified_work_items" => false })

    result = described_class.call(work_item:, paid_state: "in_progress")

    expect(result.status).to eq(:rollout_disabled)
    expect(work_item.reload.paid_lifecycle_state).to be_nil
    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
  end
end
