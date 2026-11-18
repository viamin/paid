# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Intent checkpoint context", type: :request do
  let(:owner) { create(:user, :owner) }
  let(:project) { create(:project, account: owner.account) }
  let(:feature) { create(:feature_intent, project:, status: "needs_decision") }
  let(:questions) { create_list(:feature_intent_decision, 2, feature_intent: feature) }
  let!(:checkpoint) do
    ProjectDelegation::IntentCheckpoint::Plan.call(feature_intent: feature, questions:,
      recommendation: "Start with the reviewed internal cohort.", alternatives: [ { label: "All tenants", tradeoff: "Higher risk" } ],
      consequences: [ "External customers wait for pilot evidence." ], affected_scope: { area: "rollout" },
      design_revision: "design-7", acceptance_revision: "acceptance-3").checkpoint
  end

  before { sign_in owner }

  # @spec PROJECT-DELEGATION-002
  it "shows one grouped recommendation, alternatives and consequences before answers are submitted" do
    get inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature.id}")

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.css("[data-testid='intent-checkpoint-#{checkpoint.id}']").size).to eq(1)
    expect(document.text).to include("Start with the reviewed internal cohort.", "All tenants", "Higher risk",
      "External customers wait for pilot evidence.")
    expect(document.css("form[action*='/respond']").size).to eq(2)
  end

  # @spec PROJECT-DELEGATION-002
  it "preserves the normal response path and records one immutable settlement after the final answer" do
    questions.each do |question|
      post respond_to_decision_feature_intent_path(feature, decision_id: question.id), params: { answer: "Internal cohort only." }
      expect(response).to redirect_to(inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature.id}"))
    end

    expect(checkpoint.reload).to be_settled
    expect(checkpoint.settlements.sole.answers.keys).to match_array(questions.map { |question| question.id.to_s })
    expect(feature.reload.status).to eq("needs_decision")
  end

  # @spec PROJECT-DELEGATION-002
  it "escapes stored guidance and does not expose another account's checkpoint" do
    checkpoint.update!(recommendation: "<script>window.checkpointInjected=true</script>", affected_scope: { rollout_enabled: false })
    foreign = create(:project_delegation_intent_checkpoint, recommendation: "Foreign confidential guidance")

    get inbox_entry_path("#{Inbox::Queue::FEATURE_DECISION_KIND}:#{feature.id}")

    expect(response.body).to include("&lt;script&gt;window.checkpointInjected=true&lt;/script&gt;")
    expect(response.body).not_to include("<script>window.checkpointInjected=true", foreign.recommendation)
    expect(Nokogiri::HTML(response.body).at_css("[data-testid='intent-checkpoint-#{checkpoint.id}'] details").text).to include("false")
  end

  # @spec PROJECT-DELEGATION-002
  it "exposes the same persisted group through the detail serializer and on-demand chat context" do
    entry = Inbox::Queue.new(user: owner, project:).entries.find { |candidate| candidate.record == feature }
    payload = Api::V1::InboxEntrySerializer.render(entry)
    chat = create(:chat_session, account: owner.account, project:, created_by: owner,
      inbox_item_key: entry.id, inbox_item_metadata: { "kind" => entry.kind, "record_id" => feature.id })
    context = Inbox::ChatContext.call(chat_session: chat, user: owner, sections: [ :record ])

    expect(payload.fetch(:intent_checkpoints)).to contain_exactly(hash_including(id: checkpoint.id,
      recommendation: checkpoint.recommendation, questions: questions.map { |question| { id: question.id, prompt: question.prompt } }))
    expect(context.fetch("record").fetch(:intent_checkpoints)).to eq(payload.fetch(:intent_checkpoints))
  end
end
