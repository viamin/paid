# frozen_string_literal: true

require "rails_helper"

RSpec.describe Committee::Drivers do
  let(:schema_path) { Rails.root.join("docs/api/openapi.yaml") }
  let(:schema) { YAML.safe_load_file(schema_path) }
  let(:implemented_paths) do
    [
      "/probe",
      "/probe/stream",
      "/inbox",
      "/inbox/count",
      "/inbox/entries/{entry_id}",
      "/inbox/entries/{entry_id}/chat",
      "/inbox/entries/{entry_id}/remove",
      "/inbox/entries/{entry_id}/restore",
      "/feature_intents/{id}/cancel",
      "/feature_intents/{id}/reopen",
      "/projects/{project_id}/design_artifact_findings",
      "/projects/{project_id}/design_artifact_findings/{id}/repair_document_links",
      "/chat/sessions",
      "/chat/sessions/{id}",
      "/chat/sessions/{id}/{transition}",
      "/chat/sessions/{session_id}/messages",
      "/chat/sessions/{session_id}/messages/{id}/resolve",
      "/chat/sessions/{session_id}/investigations",
      "/chat/sessions/{session_id}/investigations/{id}",
      "/chat/sessions/{session_id}/investigations/{id}/cancel",
      "/chat/sessions/{session_id}/diagrams/{diagram_id}/comments"
    ]
  end

  # @spec MOBILE-API-006 MOBILE-API-016
  it "loads and has one discriminated branch for every inbox kind" do
    expect { described_class.load_from_file(schema_path, parser_options: { strict_reference_validation: true }) }
      .not_to raise_error

    %w[InboxEntry InboxEntryListItem].each do |schema_name|
      inbox_entry = schema.dig("components", "schemas", schema_name)
      mapping = inbox_entry.fetch("discriminator").fetch("mapping")
      branch_references = inbox_entry.fetch("oneOf").map { |branch| branch.fetch("$ref") }

      expect(mapping.keys).to match_array(Inbox::Queue::KINDS)
      expect(branch_references).to match_array(mapping.values)
    end
  end

  # @spec CONFIDENCE-DELIVERY-016 OPERATOR-INBOX-021
  it "documents feature-decision delivery policy and human action payloads" do
    feature_decision = schema.dig("components", "schemas", "FeatureDecisionEntry")
    properties = feature_decision.fetch("allOf").last.fetch("properties")

    expect(properties.fetch("delivery_policy")).to include(
      "type" => "string",
      "enum" => %w[approval_gated confidence_driven]
    )
    expect(properties.fetch("human_actions")).to include(
      "type" => "array",
      "items" => {
        "type" => "object",
        "required" => %w[kind message],
        "properties" => {
          "kind" => { "type" => "string" },
          "message" => { "type" => "string" }
        }
      }
    )
  end

  # @spec OPERATOR-INBOX-021
  it "documents open feature decisions with their design claims" do
    properties = schema.dig("components", "schemas", "FeatureDecisionEntry").fetch("allOf").last.fetch("properties")

    expect(properties.fetch("decisions")).to include(
      "type" => "array",
      "items" => {
        "type" => "object",
        "required" => %w[id kind prompt design_claim],
        "properties" => {
          "id" => { "type" => "integer" },
          "kind" => { "type" => "string", "enum" => %w[question inferred_decision] },
          "prompt" => { "type" => "string" },
          "design_claim" => { "type" => "string" }
        }
      }
    )
  end

  # @spec OPERATOR-INBOX-021
  it "documents the held tasks affected by a feature decision" do
    properties = schema.dig("components", "schemas", "FeatureDecisionEntry").fetch("allOf").last.fetch("properties")

    expect(properties.fetch("affected_tasks")).to include(
      "type" => "array",
      "items" => {
        "type" => "object",
        "required" => %w[number title url],
        "properties" => {
          "number" => { "type" => "integer" },
          "title" => { "type" => "string" },
          "url" => { "type" => "string" }
        }
      }
    )
  end

  # @spec OPERATOR-INBOX-021
  it "documents design-PR revisions with their review state" do
    properties = schema.dig("components", "schemas", "FeatureDecisionEntry").fetch("allOf").last.fetch("properties")

    expect(properties.fetch("design_revisions")).to include(
      "type" => "array",
      "items" => {
        "type" => "object",
        "required" => %w[number revision state url],
        "properties" => {
          "number" => { "type" => "integer" },
          "revision" => { "type" => "string" },
          "state" => { "type" => "string", "enum" => %w[merged stale open] },
          "url" => { "type" => "string" }
        }
      }
    )
  end

  # @spec MOBILE-API-009 MOBILE-API-016
  it "documents only implemented routes with valid bearer requirements and PAT scopes" do
    expect(schema.fetch("paths").keys).to match_array(implemented_paths)
    bearer_operations.each do |operation|
      expect(operation.fetch("security")).to include("bearerAuth" => [])
    end

    scoped_operations.each do |path, operations|
      operations.each do |method, scopes|
        expect(schema.dig("paths", path, method, "x-required-pat-scopes")).to eq(scopes)
      end
    end
  end

  # @spec MOBILE-API-006 MOBILE-API-018
  it "bounds project filters to IDs PostgreSQL can resolve" do
    schema = self.schema.dig("components", "parameters", "ProjectId", "schema")

    expect(schema).to include("minimum" => 1, "maximum" => 9_223_372_036_854_775_807)
  end

  private

  def bearer_operations
    schema.fetch("paths").values.flat_map do |path_item|
      path_item.values.select { |value| value.is_a?(Hash) && value.key?("security") }
    end
  end

  def scoped_operations
    {
      "/inbox" => { "get" => [ "inbox" ] },
      "/inbox/count" => { "get" => [ "inbox" ] },
      "/inbox/entries/{entry_id}" => { "get" => [ "inbox" ] },
      "/inbox/entries/{entry_id}/chat" => { "post" => [ "chat" ] },
      "/inbox/entries/{entry_id}/remove" => { "post" => [ "inbox" ] },
      "/inbox/entries/{entry_id}/restore" => { "post" => [ "inbox" ] },
      "/feature_intents/{id}/cancel" => { "post" => [ "inbox" ] },
      "/feature_intents/{id}/reopen" => { "post" => [ "inbox" ] },
      "/projects/{project_id}/design_artifact_findings" => { "get" => [ "inbox" ] },
      "/projects/{project_id}/design_artifact_findings/{id}/repair_document_links" => { "post" => [ "inbox" ] },
      "/chat/sessions" => { "get" => [ "chat" ], "post" => [ "chat" ] },
      "/chat/sessions/{id}" => { "get" => [ "chat" ], "patch" => [ "chat" ], "delete" => [ "chat" ] },
      "/chat/sessions/{id}/{transition}" => { "patch" => [ "chat" ] },
      "/chat/sessions/{session_id}/messages" => { "get" => [ "chat" ], "post" => [ "chat" ] },
      "/chat/sessions/{session_id}/messages/{id}/resolve" => { "post" => [ "chat" ] },
      "/chat/sessions/{session_id}/investigations" => { "get" => [ "chat" ], "post" => [ "chat" ] },
      "/chat/sessions/{session_id}/investigations/{id}" => { "get" => [ "chat" ] },
      "/chat/sessions/{session_id}/investigations/{id}/cancel" => { "post" => [ "chat" ] },
      "/chat/sessions/{session_id}/diagrams/{diagram_id}/comments" => { "post" => [ "chat" ] }
    }
  end
end
