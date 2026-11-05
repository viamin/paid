# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::WorkItem do
  # @spec UNIFIED-WORK-ITEMS-001
  it "captures the normalized provider contract without losing provider detail" do
    identity = Automation::Providers::Data::ProviderIdentity.new(
      provider: :github, resource_type: :issue, external_id: "42",
      container_id: "acme/widgets", url: "https://github.com/acme/widgets/issues/42"
    )
    lifecycle = Automation::Providers::Data::Lifecycle.new(
      state: :open, raw_state: "open", mapping: :direct, conflict: nil
    )
    assignment = Automation::Providers::Data::Assignment.new(
      assignee_identities: [ "github:bob" ], provenance: :provider,
      override: Automation::Providers::Data::AssignmentOverride.new(
        assignee_identities: [ "github:paid-bot" ], actor_identity: "paid:1", reason: "triage"
      )
    )
    relation = Automation::Providers::Data::Relation.new(
      type: :blocks, target: identity, raw_type: "blocks"
    )
    attachment = Automation::Providers::Data::Attachment.new(
      id: "a1", name: "trace.txt", content_type: "text/plain", url: "https://example.test/a1", raw: { "id" => "a1" }
    )
    pull_request = Automation::Providers::Data::PullRequestRelationship.new(
      identity: identity, relation: :implements, url: identity.url
    )

    item = described_class.new(
      identity:, title: "Bug", body: "details", state: :open, raw_state: "open",
      author_identity: "github:alice", labels: [ "bug" ], comments: [], relations: [ relation ],
      attachments: [ attachment ], assignment:, lifecycle:, pull_request_relationships: [ pull_request ],
      provider_extension: Automation::Providers::Data::ProviderExtension.new(
        provider: :github, type: :github_issue, attributes: { "node_id" => "I_1" }
      ), raw_payload: { "number" => 42 }, created_at: Time.at(0), updated_at: Time.at(1), closed_at: nil,
      url: identity.url
    )

    expect(item.identity).to eq(identity)
    expect(item.assignment.override.actor_identity).to eq("paid:1")
    expect(item.relations.first.type).to eq(:blocks)
    expect(item.attachments.first.name).to eq("trace.txt")
    expect(item.pull_request_relationships.first.relation).to eq(:implements)
    expect(item.provider_extension.attributes).to include("node_id" => "I_1")
    expect(item.raw_payload).to include("number" => 42)
  end

  it "makes lifecycle mapping conflicts explicit" do
    lifecycle = Automation::Providers::Data::Lifecycle.new(
      state: :open, raw_state: "Done", mapping: :conflict,
      conflict: "provider state is terminal but the item remains open"
    )

    expect(lifecycle.conflict).to include("terminal")
  end
end
