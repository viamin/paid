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

    # Regression coverage for PR #1077: issue automation must keep queueing
    # create_pr while PR automation does not. The evaluator contract differs
    # between records by type; this test pins the "issue side" of that split
    # so a future refactor cannot quietly drop issue automation.
    context "when the record is an issue (not a pull request)" do
      let(:automation_project) do
        create(:project,
          label_mappings: {},
          automation_on_label_enabled: true,
          automation_label_name: "my-auto")
      end

      it "queues a create_pr run for an automation-labeled issue with no source_pull_request_number" do
        issue = create(:issue,
          project: automation_project,
          labels: [ "my-auto" ],
          paid_state: "new",
          is_pull_request: false)

        result = described_class.new(record: issue).call

        expect(result.to_h).to eq(
          decisions: [ { type: "queue_create_pr_run", issue_id: issue.id } ]
        )
      end
    end

    it "queues analyze_issue for a trusted paid-in-full issue when auto-pick and auto-enhance are off" do
      project = create(:project, auto_pick_enabled: false, auto_enhance_enabled: false, label_mappings: {})
      issue = create(:issue, project: project, labels: [ project.feature_activation_label_for("paid_in_full") ], paid_state: "new")
      allow(Automation::LabelPolicy).to receive(:trusted_user_added_label?)
        .with(project, issue, project.feature_activation_label_for("paid_in_full")).and_return(true)

      result = described_class.new(record: issue).call

      expect(result.to_h).to eq(decisions: [ { type: "queue_analyze_issue_run", issue_id: issue.id } ])
    end
  end
end
