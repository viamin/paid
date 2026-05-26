# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::GenerateQuestions do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) { Knowledge::ContextIntake::StartSession.call(project: project, user: user) }
  let(:service) { described_class.new(project: project, session: session, round: 2) }

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

  it "ignores malformed LLM question payloads before normalization" do
    allow(AgentHarness).to receive(:send_message).and_return(
      instance_double(
        AgentHarness::Response,
        success?: true,
        output: {
          questions: [
            "not a hash",
            { text: 123 },
            { text: "Valid follow-up", section_key: "follow_up" }
          ]
        }.to_json
      )
    )

    result = described_class.call(project: project, session: session, round: 2)

    expect(result.map(&:question_text)).to eq([ "Valid follow-up" ])
  end

  it "retries question creation when a concurrent insert wins the first key" do
    attrs = service.send(:normalize_payload, {
      "key" => "enterprise_controls",
      "text" => "What enterprise controls matter most?",
      "section_key" => "operational_constraints"
    })
    question = build(:context_intake_question, project: project, key: "enterprise_controls_2")
    attempts = 0

    allow(project.context_intake_questions).to receive(:create!) do |created_attrs|
      attempts += 1

      if attempts == 1
        expect(created_attrs[:key]).to eq("enterprise_controls")
        raise ActiveRecord::RecordNotUnique.new
      end

      expect(created_attrs[:key]).to eq("enterprise_controls_2")
      question
    end

    result = service.send(:create_question, attrs, reserved_keys: Set.new)

    expect(result).to eq(question)
    expect(attempts).to eq(2)
  end
end
