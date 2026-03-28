# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::DetectLabelsActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }
  let(:github_client) { instance_double(GithubClient, issue_events: []) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when issue has build label and is new" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build", "bug" ], paid_state: "new") }

      it "returns execute_agent action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("execute_agent")
        expect(result[:issue_id]).to eq(issue.id)
        expect(result[:project_id]).to eq(project.id)
      end

      it "updates paid_state to in_progress" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("in_progress")
      end
    end

    context "when issue has plan label and is new" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-plan" ], paid_state: "new") }

      it "returns start_planning action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("start_planning")
      end

      it "updates paid_state to planning" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("planning")
      end
    end

    context "when issue has build label but is already in_progress" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "in_progress") }

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end

      it "does not change paid_state" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("in_progress")
      end
    end

    context "when issue has no matching labels" do
      let(:issue) { create(:issue, project: project, labels: [ "bug", "enhancement" ], paid_state: "new") }

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end
    end

    context "when project has no label mappings" do
      let(:project) { create(:project, label_mappings: {}) }
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end
    end

    context "when build label takes priority over plan label" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build", "paid-plan" ], paid_state: "new") }

      it "returns execute_agent action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("execute_agent")
      end
    end

    context "when issue has open dependencies" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }
      let(:blocking_issue) { create(:issue, project: project, github_state: "open") }

      before do
        create(:issue_dependency, issue: issue, depends_on_issue: blocking_issue)
      end

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end

      it "does not change paid_state" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("new")
      end

      it "logs blocking issue numbers" do
        allow(Rails.logger).to receive(:info)

        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "github_sync.blocked_by_dependencies",
            blocking_issues: [ blocking_issue.github_number ],
            blocking_issues_count: 1,
            blocking_issues_truncated: false
          )
        )
      end
    end

    context "when issue has mixed open and closed dependencies" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }
      let(:closed_dep) { create(:issue, project: project, github_state: "closed") }
      let(:open_dep) { create(:issue, project: project, github_state: "open") }

      before do
        create(:issue_dependency, issue: issue, depends_on_issue: closed_dep)
        create(:issue_dependency, issue: issue, depends_on_issue: open_dep)
      end

      it "returns none action (all dependencies must be closed)" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end
    end

    context "when issue dependencies are all closed" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new") }
      let(:closed_dep) { create(:issue, project: project, github_state: "closed") }

      before do
        create(:issue_dependency, issue: issue, depends_on_issue: closed_dep)
      end

      it "returns execute_agent action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("execute_agent")
      end
    end

    context "when plan label issue has open dependencies" do
      let(:issue) { create(:issue, project: project, labels: [ "paid-plan" ], paid_state: "new") }
      let(:blocking_issue) { create(:issue, project: project, github_state: "open") }

      before do
        create(:issue_dependency, issue: issue, depends_on_issue: blocking_issue)
      end

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end

      it "does not change paid_state" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("new")
      end
    end

    context "when automation_on_label_enabled and issue has automation label" do
      let(:project) do
        create(:project, label_mappings: {}, automation_on_label_enabled: true, automation_label_name: "my-auto")
      end
      let(:issue) { create(:issue, project: project, labels: [ "my-auto" ], paid_state: "new") }

      it "returns execute_agent action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("execute_agent")
      end

      it "does not include source_pull_request_number for issues" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result).not_to have_key(:source_pull_request_number)
      end

      it "updates paid_state to in_progress" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("in_progress")
      end
    end

    context "when automation_on_label_enabled and a pull request has automation label" do
      let(:project) do
        create(:project, label_mappings: {}, automation_on_label_enabled: true, automation_label_name: "my-auto")
      end
      let(:pull_request) do
        create(:issue, project: project, labels: [ "my-auto" ], paid_state: "new",
               is_pull_request: true, github_number: 42)
      end

      it "returns execute_agent action with source_pull_request_number" do
        result = activity.execute(project_id: project.id, issue_id: pull_request.id)

        expect(result[:action]).to eq("execute_agent")
        expect(result[:source_pull_request_number]).to eq(42)
      end

      it "updates paid_state to in_progress" do
        activity.execute(project_id: project.id, issue_id: pull_request.id)

        expect(pull_request.reload.paid_state).to eq("in_progress")
      end
    end

    context "when automation_on_label_enabled is false" do
      let(:project) do
        create(:project, label_mappings: {}, automation_on_label_enabled: false, automation_label_name: "my-auto")
      end
      let(:issue) { create(:issue, project: project, labels: [ "my-auto" ], paid_state: "new") }

      it "returns none action even with matching automation label" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end
    end

    context "when automation_on_label_enabled but issue lacks the automation label" do
      let(:project) do
        create(:project, label_mappings: {}, automation_on_label_enabled: true, automation_label_name: "my-auto")
      end
      let(:issue) { create(:issue, project: project, labels: [ "bug" ], paid_state: "new") }

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end
    end

    context "when a pull request has build label" do
      let(:pull_request) do
        create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new",
               is_pull_request: true, github_number: 99)
      end

      it "returns execute_agent with source_pull_request_number" do
        result = activity.execute(project_id: project.id, issue_id: pull_request.id)

        expect(result[:action]).to eq("execute_agent")
        expect(result[:source_pull_request_number]).to eq(99)
      end
    end

    context "when issue is from an untrusted user" do
      let(:issue) do
        create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new",
               github_creator_login: "attacker")
      end

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end

      it "does not change paid_state" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("new")
      end

      it "logs a warning" do
        allow(Rails.logger).to receive(:warn)

        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(Rails.logger).to have_received(:warn).with(
          hash_including(
            message: "github_sync.untrusted_issue_blocked",
            creator: "attacker",
            label: "paid-build"
          )
        )
      end
    end

    context "when issue is from an untrusted user but a trusted user added the build label" do
      let(:issue) do
        create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new",
               github_creator_login: "attacker")
      end

      before do
        allow(github_client).to receive(:issue_events).with(project.full_name, issue.github_number).and_return([
          OpenStruct.new(
            event: "labeled",
            actor: OpenStruct.new(login: "viamin"),
            label: OpenStruct.new(name: "paid-build")
          )
        ])
      end

      it "returns execute_agent action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("execute_agent")
      end

      it "updates paid_state to in_progress" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("in_progress")
      end
    end

    context "when a trusted user added the label, then it was removed, and an untrusted user re-added it" do
      let(:issue) do
        create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new",
               github_creator_login: "attacker")
      end

      before do
        allow(github_client).to receive(:issue_events).with(project.full_name, issue.github_number).and_return([
          OpenStruct.new(
            event: "labeled",
            created_at: Time.utc(2025, 1, 1, 10, 0),
            actor: OpenStruct.new(login: "viamin"),
            label: OpenStruct.new(name: "paid-build")
          ),
          OpenStruct.new(
            event: "unlabeled",
            created_at: Time.utc(2025, 1, 1, 11, 0),
            actor: OpenStruct.new(login: "viamin"),
            label: OpenStruct.new(name: "paid-build")
          ),
          OpenStruct.new(
            event: "labeled",
            created_at: Time.utc(2025, 1, 1, 12, 0),
            actor: OpenStruct.new(login: "attacker"),
            label: OpenStruct.new(name: "paid-build")
          )
        ])
      end

      it "returns none action because the last labeler is untrusted" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end

      it "does not change paid_state" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.paid_state).to eq("new")
      end
    end

    context "when issue is from an untrusted user and an untrusted user added the label" do
      let(:issue) do
        create(:issue, project: project, labels: [ "paid-build" ], paid_state: "new",
               github_creator_login: "attacker")
      end

      before do
        allow(github_client).to receive(:issue_events).with(project.full_name, issue.github_number).and_return([
          OpenStruct.new(
            event: "labeled",
            actor: OpenStruct.new(login: "another-attacker"),
            label: OpenStruct.new(name: "paid-build")
          )
        ])
      end

      it "returns none action" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:action]).to eq("none")
      end
    end
  end
end
