# frozen_string_literal: true

require "rails_helper"

# @spec UNIFIED-WORK-ITEMS-001
RSpec.describe Automation::Providers::Data::WorkItem do
  let(:identity) do
    Automation::Providers::Data::WorkItemIdentity.new(
      provider: "github", resource: "acme/widgets", external_id: "42", display_id: "#42"
    )
  end

  it "retains a normalized snapshot alongside typed provider details" do
    assignment = Automation::Providers::Data::Assignment.new(
      principal: "bob", provenance: :provider, overridden: false
    )
    relation = Automation::Providers::Data::Relation.new(
      kind: :blocks,
      target: Automation::Providers::Data::WorkItemIdentity.new(
        provider: "github", resource: "acme/widgets", external_id: "43", display_id: "#43"
      )
    )
    attachment = Automation::Providers::Data::Attachment.new(
      id: "asset-1", name: "trace.txt", url: "https://example.test/asset-1", content_type: "text/plain"
    )
    pull_request = Automation::Providers::Data::PullRequestLink.new(
      provider: "github", resource: "acme/widgets", number: 42, url: "https://example.test/pull/42",
      relationship: :same_resource
    )

    item = described_class.new(
      identity:, title: "Bug", body: "details", lifecycle: :open, raw_lifecycle: "open",
      lifecycle_mapping: Automation::Providers::Data::LifecycleMapping.new(
        normalized: :open, provider_value: "open", conflict: nil
      ), author: "alice", assignments: [ assignment ], labels: [ "bug" ],
      comments: [], relations: [ relation ], attachments: [ attachment ], pull_requests: [ pull_request ],
      provider_extensions: { "github" => { "milestone" => "v1" } }, raw_payload: { "number" => 42 },
      created_at: Time.at(0), updated_at: Time.at(1), closed_at: nil, url: "https://example.test/issues/42"
    )

    expect(item.identity.external_id).to eq("42")
    expect(item.assignments).to contain_exactly(assignment)
    expect(item.relations).to contain_exactly(relation)
    expect(item.attachments).to contain_exactly(attachment)
    expect(item.pull_requests).to contain_exactly(pull_request)
    expect(item.provider_extensions).to eq("github" => { "milestone" => "v1" })
    expect(item.raw_payload).to eq("number" => 42)
  end

  it "uses explicit conflict states instead of silently discarding lifecycle ambiguity" do
    mapping = Automation::Providers::Data::LifecycleMapping.new(
      normalized: :in_progress, provider_value: "Started", conflict: :multiple_provider_states
    )

    expect(mapping.conflict?).to be(true)
    expect(mapping.normalized).to eq(:in_progress)
  end
end
