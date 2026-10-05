# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::ReconcilePartialCloseoutActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:parent) { create(:issue, :in_progress, project: project, github_state: "open") }
  let(:run) { create(:agent_run, :completed, project: project, issue: parent, pull_request_number: 99) }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:update_issue)
    allow(client).to receive(:issue) { OpenStruct.new(body: parent.body.to_s) }
  end

  describe "#execute" do
    # @spec NO-OUTPUT-ISSUE-007
    it "skips reconciliation for issue-less PR runs instead of failing them" do
      allow(Llm::AnalyzePartialCloseout).to receive(:call)
      issueless_run = create(:agent_run, :completed, :with_custom_prompt, project: project)

      result = activity.execute(agent_run_id: issueless_run.id)

      expect(result).to include(agent_run_id: issueless_run.id, status: "skipped_no_issue", gaps_remain: false)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
      expect(issueless_run.reload.reconciliation).to eq({})
    end

    it "persists the assessment on the run and reuses it across retries" do
      assessment = { "gaps" => [] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = activity.execute(agent_run_id: run.id)

      expect(result).to include(status: "reconciled", gaps_remain: false)
      expect(run.reload.reconciliation.fetch("assessment")).to eq(assessment)

      activity.execute(agent_run_id: run.id)

      expect(Llm::AnalyzePartialCloseout).to have_received(:call).once
      expect(run.reload.reconciliation).to include("assessment" => assessment, "status" => "reconciled")
    end

    # @spec NO-OUTPUT-ISSUE-007
    it "signals remaining agent-owned gaps so the workflow keeps the parent issue incomplete" do
      owner = create(:issue, project: project, github_state: "open", paid_state: "new")
      assessment = { "gaps" => [ { "criterion" => "dispatch", "kind" => "agent",
        "owner_issue_number" => owner.github_number } ] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = activity.execute(agent_run_id: run.id)

      expect(result).to include(status: "reconciled", gaps_remain: true)
      expect(parent.reload.issue_dependencies.find_by(depends_on_issue: owner)).to be_present
    end

    # @spec NO-OUTPUT-ISSUE-007
    it "signals remaining operator prerequisites so the workflow keeps the parent issue incomplete" do
      assessment = { "gaps" => [ { "criterion" => "macOS acceptance", "kind" => "human",
        "next_step" => "Run the approved macOS pilot." } ] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = activity.execute(agent_run_id: run.id)

      expect(result).to include(status: "awaiting_operator", gaps_remain: true)
      expect(Notification.where(subject: parent, blocking: true)).to exist
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
