# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetIntent do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  describe "#call" do
    let(:project) { create(:project, account: account) }
    let(:change_intent) { create(:change_intent, project: project, status: "draft") }

    it "returns the full CIR details" do
      result = tool.call(project_id: project.id, intent_id: change_intent.id)

      expect(result).to include(
        id: change_intent.id,
        project_id: project.id,
        issue_id: change_intent.issue_id,
        chat_session_id: change_intent.chat_session_id,
        status: "draft",
        title: change_intent.title,
        intent: change_intent.intent,
        behavior: change_intent.behavior,
        constraints: change_intent.constraints,
        decisions_made: change_intent.decisions_made
      )
    end

    it "raises when the CIR belongs to another project" do
      other_intent = create(:change_intent)

      expect { tool.call(project_id: project.id, intent_id: other_intent.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)
      other_intent = create(:change_intent, project: other_project)

      expect { tool.call(project_id: other_project.id, intent_id: other_intent.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
