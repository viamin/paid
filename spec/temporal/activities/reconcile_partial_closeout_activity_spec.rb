# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ReconcilePartialCloseoutActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:parent) { create(:issue, :in_progress, project: project, github_state: "open") }
  let(:run) { create(:agent_run, :completed, project: project, issue: parent, pull_request_number: 99) }

  describe "#execute" do
    it "persists the assessment on the run and reuses it across retries" do
      assessment = { "gaps" => [] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = activity.execute(agent_run_id: run.id)

      expect(result[:status]).to eq("reconciled")
      expect(run.reload.reconciliation.fetch("assessment")).to eq(assessment)

      activity.execute(agent_run_id: run.id)

      expect(Llm::AnalyzePartialCloseout).to have_received(:call).once
      expect(run.reload.reconciliation).to include("assessment" => assessment, "status" => "reconciled")
    end

    it "records a retryable failure and re-raises when reconciliation fails" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })
      allow(PartialCloseouts::Reconcile).to receive(:call).and_raise(GithubClient::Error, "github unavailable")

      expect { activity.execute(agent_run_id: run.id) }.to raise_error(GithubClient::Error)
      expect(run.reload.reconciliation.fetch("status")).to eq("retryable_failure")
      expect(run.reload.reconciliation.fetch("error")).to eq("github unavailable")
    end
  end
end
