# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::EvaluateIssuesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }
  let(:github_client) { instance_double(GithubClient, issue_events: []) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "with multiple issues" do
      let(:build_issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }
      let(:plan_issue) { create(:issue, project: project, labels: [ "paid-plan" ], paid_state: "new") }
      let(:no_label_issue) { create(:issue, project: project, labels: [ "bug" ], paid_state: "new") }

      it "returns results for all issues in a single call" do
        result = activity.execute(
          project_id: project.id,
          issue_ids: [ build_issue.id, plan_issue.id, no_label_issue.id ]
        )

        expect(result[:results].length).to eq(3)
      end

      it "evaluates each issue correctly" do
        result = activity.execute(
          project_id: project.id,
          issue_ids: [ build_issue.id, plan_issue.id, no_label_issue.id ]
        )

        actions = result[:results].map { |r| r[:action] }
        expect(actions).to eq(%w[execute_agent start_planning none])
      end

      it "updates paid_state for actionable issues" do
        activity.execute(
          project_id: project.id,
          issue_ids: [ build_issue.id, plan_issue.id, no_label_issue.id ]
        )

        expect(build_issue.reload.paid_state).to eq("in_progress")
        expect(plan_issue.reload.paid_state).to eq("planning")
        expect(no_label_issue.reload.paid_state).to eq("new")
      end

      it "preserves issue ordering in results" do
        result = activity.execute(
          project_id: project.id,
          issue_ids: [ no_label_issue.id, build_issue.id ]
        )

        expect(result[:results].map { |r| r[:issue_id] }).to eq(
          [ no_label_issue.id, build_issue.id ]
        )
      end
    end

    context "with an empty issue list" do
      it "returns empty results" do
        result = activity.execute(project_id: project.id, issue_ids: [])

        expect(result[:results]).to eq([])
      end
    end

    context "when an issue is not found" do
      let(:existing_issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }

      it "skips missing issues and continues evaluating others" do
        result = activity.execute(
          project_id: project.id,
          issue_ids: [ -1, existing_issue.id ]
        )

        expect(result[:results].length).to eq(1)
        expect(result[:results].first[:issue_id]).to eq(existing_issue.id)
      end
    end

    context "when issue has build label and is new" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }

      it "returns execute_agent action with correct decisions" do
        result = activity.execute(project_id: project.id, issue_ids: [ issue.id ])

        evaluation = result[:results].first
        expect(evaluation[:action]).to eq("execute_agent")
        expect(evaluation[:decisions]).to eq([ { type: "queue_create_pr_run", issue_id: issue.id } ])
        expect(evaluation[:issue_id]).to eq(issue.id)
        expect(evaluation[:project_id]).to eq(project.id)
      end
    end

    context "when a pull request has build label" do
      let(:pull_request) do
        create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new",
               is_pull_request: true, github_number: 99)
      end

      it "returns none because pull request automation requires scan data" do
        result = activity.execute(project_id: project.id, issue_ids: [ pull_request.id ])

        evaluation = result[:results].first
        expect(evaluation[:action]).to eq("none")
        expect(evaluation[:decisions]).to eq([ { type: "noop" } ])
      end
    end

    context "when issue has open dependencies" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }
      let(:blocking_issue) { create(:issue, project: project, github_state: "open") }

      before do
        create(:issue_dependency, issue: issue, depends_on_issue: blocking_issue)
      end

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_ids: [ issue.id ])

        expect(result[:results].first[:action]).to eq("none")
      end
    end

    context "when a rate limit error occurs mid-batch" do
      let(:first_issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }
      let(:rate_limited_issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }

      before do
        call_count = 0
        allow(Automation::Evaluator).to receive(:for).and_wrap_original do |method, issue, **kwargs|
          call_count += 1
          if call_count == 2
            raise GithubClient::RateLimitError, "API rate limit exceeded"
          end
          method.call(issue, **kwargs)
        end
      end

      it "returns results for issues processed before the rate limit" do
        result = activity.execute(
          project_id: project.id,
          issue_ids: [ first_issue.id, rate_limited_issue.id ]
        )

        expect(result[:results].length).to eq(1)
        expect(result[:results].first[:issue_id]).to eq(first_issue.id)
      end

      it "preserves state mutations for successfully processed issues" do
        activity.execute(
          project_id: project.id,
          issue_ids: [ first_issue.id, rate_limited_issue.id ]
        )

        expect(first_issue.reload.paid_state).to eq("in_progress")
        expect(rate_limited_issue.reload.paid_state).to eq("new")
      end
    end
  end
end
