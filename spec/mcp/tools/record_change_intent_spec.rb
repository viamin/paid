# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RecordChangeIntent do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  describe "#call" do
    it "creates a draft change intent for the session project" do
      result = described_class.new(user: owner, session:).call(
        title: "Prefer sliding window rate limiting",
        intent: "Smooth request limiting",
        constraints: "Use Redis"
      )

      expect(result).to include(id: kind_of(Integer), status: "draft", project_id: project.id)
      expect(project.change_intents.find(result[:id])).to have_attributes(
        title: "Prefer sliding window rate limiting",
        intent: "Smooth request limiting",
        constraints: "Use Redis",
        status: "draft"
      )
    end
  end

  describe "#resolve_confirmation" do
    it "activates and indexes the draft on approval" do
      change_intent = create(:change_intent, :draft, project:, chat_session: session)
      allow(ChangeIntents::Activate).to receive(:call).and_call_original

      result = described_class.new(user: owner, session:).resolve_confirmation(
        decision: :approve,
        pending_result: { "id" => change_intent.id }
      )

      expect(result).to include(id: change_intent.id, status: "active")
      expect(ChangeIntents::Activate).to have_received(:call).with(change_intent:)
    end

    it "deletes the draft on denial" do
      change_intent = create(:change_intent, :draft, project:, chat_session: session)

      result = described_class.new(user: owner, session:).resolve_confirmation(
        decision: :deny,
        pending_result: { "id" => change_intent.id }
      )

      expect(result).to include(id: change_intent.id, status: "denied", disposition: "deleted_draft")
      expect(ChangeIntent.where(id: change_intent.id)).to be_empty
    end
  end
end
