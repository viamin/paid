# frozen_string_literal: true

require "rails_helper"

# @spec CHANGE-INTENT-004
RSpec.describe ChangeIntents::DraftFromIssue do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :in_progress, project: project) }

  describe ".call" do
    context "when the payload describes a non-obvious constraint" do
      let(:payload) do
        {
          title: "Sliding window rate limiting over token bucket",
          intent: "Smooth per-user request limiting for the public API.",
          behavior: "Given bursty traffic, keep limits even across the window.",
          constraints: "Use Redis and follow the auth middleware layout.",
          decisions_made: "Rejected token bucket; harder to reason about for support."
        }
      end

      it "creates an issue-linked draft change intent" do
        result = described_class.call(project: project, issue: issue, payload: payload)

        expect(result).to be_a(ChangeIntent)
        expect(result).to have_attributes(
          project: project,
          issue: issue,
          status: "draft",
          title: "Sliding window rate limiting over token bucket",
          intent: "Smooth per-user request limiting for the public API.",
          constraints: "Use Redis and follow the auth middleware layout.",
          decisions_made: "Rejected token bucket; harder to reason about for support."
        )
      end

      it "does not index the draft into the knowledge pipeline" do
        expect(ChangeIntents::SyncKnowledgeArtifact).not_to receive(:call)

        described_class.call(project: project, issue: issue, payload: payload)
      end

      it "revises the existing draft instead of creating a duplicate" do
        existing = create(:change_intent, :draft, project: project, issue: issue,
                                                   title: "Existing draft", intent: "Existing intent")

        result = described_class.call(project: project, issue: issue, payload: payload)

        expect(result.id).to eq(existing.id)
        expect(result).to have_attributes(title: payload[:title], intent: payload[:intent])
        expect(issue.change_intents.draft.count).to eq(1)
      end

      it "revises a requested-changes draft and clears its addressed feedback" do
        existing = create(:change_intent, project: project, issue: issue, status: "requested_changes",
                                           requested_changes_at: 1.hour.ago,
                                           requested_changes_reason: "Clarify the constraint.")

        result = described_class.call(project: project, issue: issue, payload: payload)

        expect(result).to have_attributes(
          id: existing.id,
          status: "draft",
          requested_changes_at: nil,
          requested_changes_reason: nil
        )
      end
    end

    context "when the issue body is not CIR-worthy" do
      it "returns nil and creates no record when the payload is absent" do
        result = described_class.call(project: project, issue: issue, payload: nil)

        expect(result).to be_nil
        expect(ChangeIntent.count).to eq(0)
      end

      it "returns nil when the payload lacks a title" do
        result = described_class.call(
          project: project, issue: issue,
          payload: { intent: "Smooth limiting" }
        )

        expect(result).to be_nil
        expect(ChangeIntent.count).to eq(0)
      end

      it "returns nil when the payload lacks intent" do
        result = described_class.call(
          project: project, issue: issue,
          payload: { title: "Sliding window" }
        )

        expect(result).to be_nil
        expect(ChangeIntent.count).to eq(0)
      end

      it "returns nil when the payload is a blank self-evident constraint" do
        result = described_class.call(
          project: project, issue: issue,
          payload: { title: "  ", intent: "" }
        )

        expect(result).to be_nil
        expect(ChangeIntent.count).to eq(0)
      end
    end

    context "when behavior and decisions are optional" do
      it "creates a draft with only the required title and intent" do
        result = described_class.call(
          project: project, issue: issue,
          payload: { title: "Avoid global state", intent: "Keep modules self-contained." }
        )

        expect(result).to have_attributes(
          behavior: nil,
          constraints: nil,
          decisions_made: nil,
          status: "draft"
        )
      end
    end
  end
end
