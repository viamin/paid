# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DraftDecisionRecordActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, :completed, project: project) }

  describe "#execute" do
    it "returns success when a decision record is drafted" do
      record = create(:decision_record, agent_run: agent_run, project: project)
      allow(Knowledge::Decisions::Draft).to receive(:call).and_return(record)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be true
      expect(result[:decision_record_id]).to eq(record.id)
      expect(result[:agent_run_id]).to eq(agent_run.id)
    end

    it "returns success with nil decision_record_id when draft is skipped" do
      allow(Knowledge::Decisions::Draft).to receive(:call).and_return(nil)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be true
      expect(result[:decision_record_id]).to be_nil
    end

    it "returns failure without raising when draft errors" do
      allow(Knowledge::Decisions::Draft).to receive(:call).and_raise(StandardError, "LLM timeout")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:success]).to be false
      expect(result[:error]).to eq("LLM timeout")
    end
  end
end
