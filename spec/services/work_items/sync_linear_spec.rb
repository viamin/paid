# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::SyncLinear do
  let(:project) { create(:project) }
  let(:account) { project.account }
  let(:token) { create(:linear_token, account:) }
  let(:configuration) { create(:tracker_configuration, :linear, configurable: account, linear_token: token) }
  let(:ticket) do
    { id: "issue-1", identifier: "ENG-1", title: "Build feature", description: "Details",
      url: "https://linear.app/acme/issue/ENG-1", priority: 2, updatedAt: "2026-11-10T12:00:00.000Z",
      createdAt: "2026-11-09T12:00:00.000Z", archivedAt: nil,
      state: { id: "state-1", name: "Todo", type: "unstarted" },
      team: { id: "team-1", key: "ENG", name: "Engineering" },
      project: { id: "linear-project-1", name: "Roadmap" },
      labels: { nodes: [ { id: "label-1", name: "Feature" } ] } }
  end

  before { configuration }

  def stub_ticket
    stub_request(:post, "https://api.linear.app/graphql").to_return(
      status: 200,
      body: JSON.generate(data: { issues: { nodes: [ ticket ],
        pageInfo: { hasNextPage: false, endCursor: "end" } } })
    )
  end

  it "upserts a ticket by provider identity without creating duplicates or reposting comments" do
    # @spec UNIFIED-WORK-ITEMS-003
    stub_ticket
    FeatureFlags.enable!(:unified_work_items, project:)

    expect { described_class.call(project:) }.to change(WorkItem, :count).by(1)
    expect { described_class.call(project:) }.not_to change(WorkItem, :count)

    item = WorkItem.find_by!(account:, provider: "linear", external_id: "issue-1")
    expect(item.title).to eq("Build feature")
    expect(item.raw_payload.fetch("identifier")).to eq("ENG-1")
    expect(item.provider_updated_at.utc.iso8601).to eq("2026-11-10T12:00:00Z")
    expect(a_request(:post, "https://api.linear.app/graphql").with { |request|
      JSON.parse(request.body).fetch("query").include?("commentCreate")
    }).not_to have_been_made
  end

  it "does not call Linear while the rollout guard is disabled" do
    # @spec UNIFIED-WORK-ITEMS-009
    expect(described_class.call(project:)).to eq(0)
    expect(a_request(:post, "https://api.linear.app/graphql")).not_to have_been_made
  end

  it "records rate-limit health without changing previously imported tickets" do
    # @spec UNIFIED-WORK-ITEMS-002 UNIFIED-WORK-ITEMS-003
    FeatureFlags.enable!(:unified_work_items, project:)
    existing = WorkItem.create!(account:, tracker_configuration: configuration, provider: "linear",
      resource_type: "issue", external_id: "issue-1", title: "Existing", last_synced_at: 1.hour.ago)
    stub_request(:post, "https://api.linear.app/graphql").to_return(status: 429,
      headers: { "Retry-After" => "20" },
      body: JSON.generate(errors: [ { message: "Rate limited", extensions: { code: "RATELIMITED" } } ]))

    expect { described_class.call(project:) }.to raise_error(IssueTrackers::Adapters::Linear::RateLimitedError)
    expect(configuration.reload.connection_health).to eq("rate_limited")
    expect(existing.reload.title).to eq("Existing")
  end

  it "reconciles a changed provider lifecycle state through the configured mapping" do
    # @spec UNIFIED-WORK-ITEMS-006
    FeatureFlags.enable!(:unified_work_items, project:)
    create(:work_item_lifecycle_mapping, account:, native_state: "In Progress", paid_state: "in_progress")
    item = create(:work_item, account:, tracker_configuration: configuration, external_id: "issue-1",
      native_state: "Todo", paid_lifecycle_state: "todo")
    ticket[:state][:name] = "In Progress"
    stub_ticket

    described_class.call(project:)

    expect(item.reload).to have_attributes(native_state: "In Progress", paid_lifecycle_state: "in_progress",
      lifecycle_sync_source: "provider")
  end

  it "records a conflict instead of overwriting a recent Paid lifecycle change" do
    # @spec UNIFIED-WORK-ITEMS-006
    FeatureFlags.enable!(:unified_work_items, project:)
    create(:work_item_lifecycle_mapping, account:, native_state: "In Progress", paid_state: "in_progress")
    item = create(:work_item, account:, tracker_configuration: configuration, external_id: "issue-1",
      native_state: "Todo", paid_lifecycle_state: "blocked", lifecycle_sync_source: "paid")
    ticket[:state][:name] = "In Progress"
    stub_ticket

    expect { described_class.call(project:) }.to change(WorkItemLifecycleConflict, :count).by(1)

    expect(item.reload).to have_attributes(native_state: "Todo", paid_lifecycle_state: "blocked")
    expect(item.work_item_lifecycle_conflicts.last).to have_attributes(requested_native_state: "In Progress",
      requested_paid_state: "in_progress")
  end
end
