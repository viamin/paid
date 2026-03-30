# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiagnoseErrorJob do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token) }
  let(:agent_run) { create(:agent_run, :failed, project: project, diagnosis_status: "in_progress") }

  it "discards when agent run is not found" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  describe "#perform" do
    context "when diagnosis succeeds" do
      let(:result) do
        AgentRuns::DiagnoseError::Result.new(
          success: true,
          issue_url: "https://github.com/example/repo/issues/99"
        )
      end

      before do
        allow(AgentRuns::DiagnoseError).to receive(:call).and_return(result)
      end

      it "updates diagnosis_status to completed" do
        described_class.new.perform(agent_run.id)

        agent_run.reload
        expect(agent_run.diagnosis_status).to eq("completed")
        expect(agent_run.diagnosis_issue_url).to eq("https://github.com/example/repo/issues/99")
      end
    end

    context "when diagnosis fails" do
      let(:result) do
        AgentRuns::DiagnoseError::Result.new(
          success: false,
          message: "No diagnosis could be determined."
        )
      end

      before do
        allow(AgentRuns::DiagnoseError).to receive(:call).and_return(result)
      end

      it "updates diagnosis_status to failed" do
        described_class.new.perform(agent_run.id)

        expect(agent_run.reload.diagnosis_status).to eq("failed")
      end
    end

    context "when an unexpected error occurs" do
      before do
        allow(AgentRuns::DiagnoseError).to receive(:call).and_raise(StandardError, "unexpected")
      end

      it "sets diagnosis_status to failed" do
        described_class.new.perform(agent_run.id)

        expect(agent_run.reload.diagnosis_status).to eq("failed")
      end
    end
  end
end
