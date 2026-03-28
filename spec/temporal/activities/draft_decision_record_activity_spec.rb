# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DraftDecisionRecordActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }

  let(:llm_json) do
    {
      title: "Use JWT for auth",
      summary: "Decided to use JWT.",
      context: "Session auth was insufficient.",
      decision: "Implement JWT auth.",
      consequences: "Clients must refresh tokens.",
      tags: %w[auth api]
    }.to_json
  end

  let(:llm_response) do
    response = Object.new
    json = llm_json
    response.define_singleton_method(:output) { json }
    response.define_singleton_method(:success?) { true }
    response
  end

  before do
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
  end

  describe "#execute" do
    before do
      agent_run.log!("stdout", "Implemented JWT authentication for API endpoints")
    end

    it "returns success when a decision record is drafted" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be true
      expect(result[:decision_record_id]).to be_present
      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(AgentHarness).to have_received(:send_message)
    end

    it "returns success with nil decision_record_id when LLM returns empty output" do
      allow(llm_response).to receive(:output).and_return("")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be true
      expect(result[:decision_record_id]).to be_nil
    end

    it "returns existing record without calling LLM (idempotency)" do
      record = create(:decision_record, agent_run: agent_run, project: project)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(AgentHarness).not_to have_received(:send_message)
      expect(result[:success]).to be true
      expect(result[:decision_record_id]).to eq(record.id)
    end

    it "returns failure when agent_run_id is nil" do
      result = activity.execute(agent_run_id: nil)

      expect(result[:success]).to be false
      expect(result[:error]).to eq("agent_run_id is required")
    end

    it "returns success with nil record when AgentHarness errors (Draft rescues internally)" do
      allow(AgentHarness).to receive(:send_message).and_raise(AgentHarness::Error, "LLM timeout")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be true
      expect(result[:decision_record_id]).to be_nil
    end

    it "returns failure without raising when an unexpected error occurs" do
      allow(AgentHarness).to receive(:send_message).and_raise(RuntimeError, "unexpected")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be false
      expect(result[:error]).to eq("unexpected")
    end

    it "re-raises Temporalio::Error::CanceledError instead of swallowing it" do
      allow(AgentHarness).to receive(:send_message).and_raise(Temporalio::Error::CanceledError, "activity canceled")

      expect { activity.execute(agent_run_id: agent_run.id) }.to raise_error(Temporalio::Error::CanceledError)
    end
  end
end
