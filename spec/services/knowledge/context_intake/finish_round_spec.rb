# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::FinishRound do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) { Knowledge::ContextIntake::StartSession.call(project: project, user: user) }

  before do
    {
      "product_description" => "Enterprise SaaS for finance teams.",
      "primary_users" => "Finance operators at mid-market companies.",
      "critical_journeys" => "Close the month-end books without manual exports.",
      "deployment_model" => "Multi-tenant SaaS."
    }.each do |question_key, answer_text|
      session.context_intake_responses.find_by!(question_key: question_key).update!(answer_text: answer_text)
    end
  end

  it "returns the next authored follow-up question and enqueues non-blocking agent generation" do
    create_follow_up_question!

    expect {
      result = described_class.call(
        session: session,
        project: project,
        current_question_key: "naming_conventions",
        agent_generation_enabled: true
      )

      expect(result.next_question_key).to eq("enterprise_approvals")
      expect(result).not_to be_pending_generation
      expect(result).not_to be_completed
    }.to have_enqueued_job(Knowledge::ContextIntake::GenerateFollowUpQuestionsJob)
      .with(session_id: session.id, project_id: project.id, current_round: 1, blocking: false)

    expect(session.reload.metadata).to include(
      "follow_up_generation_attempted_rounds" => [ 1 ],
      "follow_up_generation" => include("status" => "pending", "round" => 2, "blocking" => false)
    )
  end

  it "marks the round attempted and completes when no more questions are available" do
    result = described_class.call(
      session: session,
      project: project,
      current_question_key: "naming_conventions",
      agent_generation_enabled: false
    )

    expect(result.next_question_key).to be_nil
    expect(result).not_to be_pending_generation
    expect(result).to be_completed
    expect(session.reload.metadata["follow_up_generation_attempted_rounds"]).to eq([ 1 ])
    expect(session).to be_completed
  end

  def create_follow_up_question!
    create(
      :context_intake_question,
      project: project,
      key: "enterprise_approvals",
      question_text: "Which enterprise approvals or governance steps block releases?",
      section_key: "operational_constraints",
      section_title: "Operational & Business Constraints",
      category: "operational_constraints",
      round: 2,
      section_order: 6,
      display_order: 0,
      is_follow_up: true,
      parent_question_key: "product_description",
      conditions: {
        "depends_on_question_key" => "product_description",
        "answer_includes_any" => [ "enterprise" ]
      }
    )
  end
end
