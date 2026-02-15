# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::DetectLabelsActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }

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
            creator: "attacker"
          )
        )
      end
    end
  end
end
