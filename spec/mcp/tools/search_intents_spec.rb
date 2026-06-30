# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::SearchIntents do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }

  def create_intent(title:, intent:, status:, **attrs)
    create(:change_intent, {
      project: project,
      status: status,
      title: title,
      intent: intent,
      behavior: nil,
      constraints: nil,
      decisions_made: nil
    }.merge(attrs))
  end

  def matching_result_ids(query)
    tool.call(project_id: project.id, query: query, limit: 10).map { |entry| entry[:id] }
  end

  def seed_throttling_intents
    stale_match = create_intent(
      status: "superseded",
      title: "Older throttling direction",
      intent: "Use Redis for throttling."
    )
    active_match = create_intent(
      status: "active",
      title: "Preferred throttling direction",
      intent: "Use Redis for throttling."
    )
    create_intent(
      status: "active",
      title: "Unrelated auth direction",
      intent: "Rotate session cookies daily."
    )

    [ active_match, stale_match ]
  end

  describe "#call" do
    it "returns matching CIRs ordered with active records first" do
      active_match, stale_match = seed_throttling_intents

      result = tool.call(project_id: project.id, query: "redis throttling", limit: 10)

      expect(matching_result_ids("redis throttling")).to eq([ active_match.id, stale_match.id ])
      expect(result.first).to include(
        title: "Preferred throttling direction",
        status: "active",
        issue_id: active_match.issue_id
      )
    end

    it "raises when query is blank" do
      expect { tool.call(project_id: project.id, query: "   ") }
        .to raise_error(ArgumentError, "query is required")
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, query: "redis") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
