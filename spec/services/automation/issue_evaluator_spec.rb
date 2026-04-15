# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::IssueEvaluator do
  describe "#call" do
    let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }

    it "queues an explicit create_pr decision for build-labeled issues" do
      issue = create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new")

      result = described_class.new(record: issue).call

      expect(result.to_h).to eq(
        decisions: [
          {
            type: "queue_create_pr_run",
            issue_id: issue.id
          }
        ]
      )
    end

    it "returns noop when dependencies block automation" do
      issue = create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new")
      blocking_issue = create(:issue, project: project, github_state: "open")
      create(:issue_dependency, issue: issue, depends_on_issue: blocking_issue)

      result = described_class.new(record: issue).call

      expect(result.to_h).to eq(decisions: [ { type: "noop" } ])
    end
  end
end
