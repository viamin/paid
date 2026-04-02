# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::UpdatePlanningLabelsActivity do
  let(:activity) { described_class.new }
  let(:project) do
    create(:project, label_mappings: { "plan" => "paid:planning", "build" => "paid:build" })
  end
  let(:issue) { create(:issue, :planning, project: project) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:remove_label_from_issue)
    allow(github_client).to receive(:add_labels_to_issue)
  end

  describe "#execute" do
    context "with multiple tasks (decomposed feature)" do
      it "removes the plan label" do
        activity.execute(project_id: project.id, issue_id: issue.id, task_count: 3)

        expect(github_client).to have_received(:remove_label_from_issue).with(
          project.full_name,
          issue.github_number,
          project.label_for_stage(:plan)
        )
      end

      it "does not add the build label" do
        activity.execute(project_id: project.id, issue_id: issue.id, task_count: 3)

        expect(github_client).not_to have_received(:add_labels_to_issue)
      end

      it "keeps the issue in planning state" do
        activity.execute(project_id: project.id, issue_id: issue.id, task_count: 3)

        expect(issue.reload.paid_state).to eq("planning")
      end
    end

    context "with a single task (simple feature)" do
      it "removes the plan label and adds build label" do
        activity.execute(project_id: project.id, issue_id: issue.id, task_count: 1)

        expect(github_client).to have_received(:remove_label_from_issue)
        expect(github_client).to have_received(:add_labels_to_issue).with(
          project.full_name,
          issue.github_number,
          [ project.label_for_stage(:build) ]
        )
      end

      it "transitions the issue to in_progress state" do
        activity.execute(project_id: project.id, issue_id: issue.id, task_count: 1)

        expect(issue.reload.paid_state).to eq("in_progress")
      end
    end

    context "with zero tasks" do
      it "transitions the issue to in_progress state" do
        activity.execute(project_id: project.id, issue_id: issue.id, task_count: 0)

        expect(issue.reload.paid_state).to eq("in_progress")
      end
    end

    context "when label operations fail" do
      before do
        allow(github_client).to receive(:remove_label_from_issue).and_raise(StandardError.new("API error"))
      end

      it "does not raise (best-effort)" do
        expect {
          activity.execute(project_id: project.id, issue_id: issue.id, task_count: 3)
        }.not_to raise_error
      end
    end
  end
end
