# frozen_string_literal: true

require "rails_helper"

# @spec FACET-CONFIDENCE-005
RSpec.describe Tools::ChallengeFacetAssessment do
  let(:account) { create(:account) }
  let(:user) { create(:user, :admin, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:session) { create(:chat_session, account:, created_by: user, project:) }
  let(:facet) { create(:feature_intent_facet, feature_intent: create(:feature_intent, project:)) }
  let(:direction) { create(:feature_intent_facet_direction, feature_intent_facet: facet) }
  let!(:message) { create(:chat_message, chat_session: session, role: "user", content: "Keyboard controls are required.") }

  it "records an explicit, authorized chat correction and queues reassessment" do
    direction

    expect {
      result = described_class.new(user:, session:).call(facet_id: facet.id, statement: message.content,
        chat_message_id: message.id, confirmed: true)
      expect(result).to include(status: "pending")
    }.to have_enqueued_job(FeatureIntents::AssessFacetJob)

    evidence = facet.evidence.last
    expect(evidence).to have_attributes(actor: user, source_reference: "chat-message:#{message.external_id}")
  end
end
