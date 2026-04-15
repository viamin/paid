# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::PullRequestEvaluator do
  describe "#call" do
    let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }
    let(:pull_request) do
      create(:issue, :pull_request,
        project: project,
        labels: [ "paid-build" ],
        paid_state: "new",
        github_number: 42)
    end

    it "keeps legacy initial-sync create_pr behavior when the flag is disabled" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: false).call

      expect(result.to_h).to eq(
        decisions: [
          {
            type: "queue_create_pr_run",
            issue_id: pull_request.id,
            source_pull_request_number: 42
          }
        ]
      )
    end

    it "returns noop for initial-sync PR evaluation when the flag is enabled" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call

      expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
    end

    it "maps paid_agent review signals to an explicit review decision" do
      result = described_class.new(record: pull_request, explicit_pr_decisions: true).call(scan: {
        issue_id: pull_request.id,
        pr_number: 42,
        phase: "ready",
        triggers: [ { type: "paid_agent_review_pending" } ]
      })

      expect(result.to_h).to eq(
        decisions: [
          {
            type: "queue_review_run",
            issue_id: pull_request.id,
            source_pull_request_number: 42
          }
        ]
      )
    end
  end
end
