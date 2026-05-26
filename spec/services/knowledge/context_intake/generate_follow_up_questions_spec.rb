# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::GenerateFollowUpQuestions do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) { Knowledge::ContextIntake::StartSession.call(project: project, user: user) }

  before do
    session.context_intake_responses.find_by!(question_key: "product_description").update!(answer_text: "Enterprise SaaS for finance teams.")
    allow(Knowledge::ContextIntake::GenerateQuestions).to receive(:call).and_return([])
  end

  it "appends authored follow-up questions for the next round when conditions match" do
    create_follow_up_question!

    result = described_class.call(
      session: session,
      project: project,
      current_question_key: "naming_conventions"
    )

    response = session.context_intake_responses.find_by!(question_key: "enterprise_approvals")
    expect(response.parent_response.question_key).to eq("product_description")
    expect(result.next_question_key).to eq("enterprise_approvals")
    expect(session.reload.metadata["follow_up_generation_attempted_rounds"]).to eq([ 1 ])
  end

  it "does not call GenerateQuestions when generate_with_agent is false" do
    create_follow_up_question!

    described_class.call(
      session: session,
      project: project,
      current_question_key: "naming_conventions",
      generate_with_agent: false
    )

    expect(Knowledge::ContextIntake::GenerateQuestions).not_to have_received(:call)
  end

  it "calls GenerateQuestions when generate_with_agent is true" do
    create_follow_up_question!

    described_class.call(
      session: session,
      project: project,
      current_question_key: "naming_conventions",
      generate_with_agent: true
    )

    expect(Knowledge::ContextIntake::GenerateQuestions).to have_received(:call).with(
      project: project,
      session: session,
      round: 2,
      auto_approve: true
    )
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
