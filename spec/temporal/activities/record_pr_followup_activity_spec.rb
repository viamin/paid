# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::RecordPrFollowupActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when project is missing" do
      it "returns recorded: false" do
        result = activity.execute(project_id: -1, issue_id: 1)

        expect(result[:recorded]).to be false
      end
    end

    context "when issue is missing" do
      it "returns recorded: false" do
        result = activity.execute(project_id: project.id, issue_id: -1)

        expect(result[:recorded]).to be false
      end
    end

    context "when recording a follow-up" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated" ],
          pr_followup_count: 0)
      end

      it "increments pr_followup_count" do
        activity.execute(project_id: project.id, issue_id: issue.id)

        expect(issue.reload.pr_followup_count).to eq(1)
      end

      it "returns recorded: true" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:recorded]).to be true
      end
    end

    context "when labels_to_remove is provided" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-rework" ])
      end

      before do
        allow(github_client).to receive(:remove_label_from_issue)
      end

      it "removes the specified labels" do
        activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          labels_to_remove: [ "paid-rework" ]
        )

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(project.full_name, 42, "paid-rework")
      end
    end

    context "when label removal fails" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated", "paid-rework" ])
      end

      before do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error, "label not found")
        allow(Rails.logger).to receive(:warn)
      end

      it "logs the error and continues" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          labels_to_remove: [ "paid-rework" ]
        )

        expect(result[:recorded]).to be true
        expect(Rails.logger).to have_received(:warn).with(
          hash_including(message: "pr_scanner.remove_label_failed")
        )
      end
    end

    context "when labels_to_remove is empty" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          labels: [ "paid-generated" ])
      end

      it "does not attempt to remove labels" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          labels_to_remove: []
        )

        expect(result[:recorded]).to be true
      end
    end
  end
end
