# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::ContextIntake::GenerateQuestions do
  let(:project) { create(:project) }
  let(:user) { create(:user, account: project.account) }
  let(:session) { Knowledge::ContextIntake::StartSession.call(project: project, user: user) }
  let(:service) { described_class.new(project: project, session: session, round: 2) }

  let(:parsed_payload) do
    {
      "questions" => [
        {
          "key" => "enterprise_controls",
          "text" => "What enterprise controls or approval steps most affect deployments?",
          "section_key" => "operational_constraints",
          "section_title" => "Operational & Business Constraints",
          "category" => "operational_constraints",
          "required" => false,
          "parent_question_key" => "product_description"
        }
      ]
    }
  end

  let(:legacy_response) do
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: parsed_payload.to_json
    )
  end

  before do
    allow(AgentHarness).to receive(:send_message).and_return(legacy_response)
    allow(Llm::TextMode).to receive_messages(options: {}, enabled?: false)
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

  # @spec CONTEXT-INTAKE-004
  context "when API-key authentication is configured" do
    let(:chat_transport) { instance_double(AgentHarness::Api::ChatTransport, call: schema_result) }

    let(:schema_result) do
      {
        status: :succeeded,
        content: parsed_payload.to_json,
        parsed: parsed_payload
      }
    end

    before do
      stub_const("ENV", ENV.to_hash.merge("ANTHROPIC_API_KEY" => "sk-ant-test-key"))
      allow(Llm::TextMode).to receive(:enabled?).and_return(true)
      allow(AgentHarness::Api::ChatTransport).to receive(:new).and_return(chat_transport)
    end

it "routes through the schema-constrained ChatTransport without parsing JSON text" do
        result = described_class.call(project: project, session: session, round: 2)

        expect(result.map(&:question_text)).to eq([ "What enterprise controls or approval steps most affect deployments?" ])
        expect(AgentHarness::Api::ChatTransport).to have_received(:new) do
          expect(chat_transport).to have_received(:call) do |request|
            expect(request[:operation]).to eq(:schema)
            expect(request[:schema_name]).to eq("context_intake_follow_up_questions")
            expect(request[:schema]).to eq(described_class::RESPONSE_SCHEMA)
            expect(request[:schema_mode]).to eq(:json_schema)
            expect(request[:candidates].first).to include(
              provider: :anthropic,
              model: described_class::DEFAULT_MODEL,
              authentication_mode: :api_key
            )
          end
        end
        expect(AgentHarness).not_to have_received(:send_message)
      end

    it "returns no questions for missing fields or failed schema responses" do
      [ {}, nil, { "questions" => [] } ].each do |parsed|
        allow(chat_transport).to receive(:call).and_return(status: :succeeded, parsed: parsed)

        expect(described_class.call(project: project, session: session, round: 2)).to be_empty
      end
    end

    it "returns no questions when the schema result did not succeed" do
      allow(chat_transport).to receive(:call).and_return(status: :failed, parsed: nil, error: { code: :invalid_schema })

      expect(described_class.call(project: project, session: session, round: 2)).to be_empty
    end

    it "returns no questions when the schema result is missing" do
      allow(chat_transport).to receive(:call).and_return(nil)

      expect(described_class.call(project: project, session: session, round: 2)).to be_empty
    end

    it "returns no questions when no API key is configured despite text mode reporting enabled" do
      stub_const("ENV", ENV.to_hash.except("ANTHROPIC_API_KEY"))

      expect(described_class.call(project: project, session: session, round: 2)).to be_empty
    end
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
