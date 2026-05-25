# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::GenerateQuestions do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) { Knowledge::ContextIntake::StartSession.call(project: project, user: user) }

  before do
    allow(AgentHarness).to receive(:send_message).and_return(
      instance_double(
        AgentHarness::Response,
        success?: true,
        output: {
          questions: [
            {
              key: "enterprise_controls",
              text: "What enterprise controls or approval steps most affect deployments?",
              section_key: "operational_constraints",
              section_title: "Operational & Business Constraints",
              category: "operational_constraints",
              required: false,
              parent_question_key: "product_description"
            }
          ]
        }.to_json
      )
    )
  end

  it "stores generated questions in the same catalog schema with pending review by default" do
    result = described_class.call(project: project, session: session, round: 2)

    question = result.fetch(0)
    expect(question.project).to eq(project)
    expect(question.status).to eq("pending_review")
    expect(question.provenance).to eq("agent")
    expect(question.is_follow_up).to be(true)
    expect(question.round).to eq(2)
    expect(question.parent_question_key).to eq("product_description")
  end

  it "can auto-approve generated questions for direct presentation" do
    result = described_class.call(project: project, session: session, round: 2, auto_approve: true)

    expect(result.fetch(0).status).to eq("approved")
  end
end
