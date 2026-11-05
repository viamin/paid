# frozen_string_literal: true

require "rails_helper"

# @spec UNIFIED-WORK-ITEMS-001
RSpec.describe Automation::Providers::Data::WorkItem do
  let(:identity) do
    Automation::Providers::Data::WorkItem::Identity.new(
      provider: :github, resource_type: :issue, resource_id: "42", container_id: "acme/widgets"
    )
  end

  it "retains normalized, provider-specific, and raw representations without conflating them" do
    item = described_class.new(
      identity:, title: "Bug", body: "Details", author: nil, labels: [], lifecycle: described_class::Lifecycle.new(
        state: :open, raw_state: "OPEN", mapping: :direct, conflict: nil
      ), comments: [], relations: [], attachments: [], assignments: [], pull_request_links: [],
      provider_extensions: [ described_class::Extension.new(provider: :github, type: :github_issue, attributes: { "node_id" => "I_1" }) ],
      raw_payload: { "state" => "OPEN" }, created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 2),
      url: "https://github.com/acme/widgets/issues/42"
    )

    expect(item.identity.provider).to eq(:github)
    expect(item.lifecycle.state).to eq(:open)
    expect(item.provider_extensions.first.attributes).to eq({ "node_id" => "I_1" })
    expect(item.raw_payload).to eq({ "state" => "OPEN" })
  end

  it "models assignment origin and an explicit Paid override" do
    assignment = described_class::Assignment.new(
      assignee: described_class::Actor.new(provider: :github, external_id: "7", login: "alice"),
      provenance: :provider, overridden_by: described_class::Actor.new(provider: :paid, external_id: "19", login: "operator"),
      overridden_at: Time.utc(2026, 1, 3)
    )

    expect(assignment.provenance).to eq(:provider)
    expect(assignment.overridden_by.login).to eq("operator")
  end

  it "uses explicit links for work-item to pull-request relationships" do
    link = described_class::PullRequestLink.new(
      identity: described_class::Identity.new(provider: :github, resource_type: :pull_request, resource_id: "43", container_id: "acme/widgets"),
      relationship: :implements, url: "https://github.com/acme/widgets/pull/43"
    )

    expect(link.relationship).to eq(:implements)
    expect(link.identity.resource_type).to eq(:pull_request)
  end
end
