# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# Focused coverage for the label cleanup performed by #maybe_restart_draft when
# a PR is converted back to draft on GitHub. Without it, the paid-escalated
# label persists on the host and is re-synced into the local labels array,
# leaving an already-resumed PR visually flagged as escalated.
RSpec.describe Activities::ScanPaidPrsActivity do
  describe "#maybe_restart_draft label cleanup" do
    let(:activity) { described_class.new }
    let(:github_client) { instance_double(GithubClient) }
    let(:project) { create(:project) }
    let(:pr_data) { OpenStruct.new(draft: true) }

    before do
      allow(project).to receive(:client).and_return(github_client)
      allow(github_client).to receive(:remove_label_from_issue)
      # invalidate_pr_progress_state clears derived caches that are irrelevant
      # here and require extra setup; the restart transition is the subject.
      allow(activity).to receive(:invalidate_pr_progress_state)
    end

    context "when the PR carries the paid-escalated label" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          pr_review_phase: "escalated",
          labels: [ "paid-generated", described_class::PAID_ESCALATED_LABEL ])
      end

      it "restarts the phase" do
        activity.send(:maybe_restart_draft, project, issue, pr_data)

        expect(issue.reload.pr_review_phase).to eq("restarted")
      end

      it "strips the label from the local labels array" do
        activity.send(:maybe_restart_draft, project, issue, pr_data)

        expect(issue.reload.labels).not_to include(described_class::PAID_ESCALATED_LABEL)
      end

      it "removes the label on GitHub" do
        activity.send(:maybe_restart_draft, project, issue, pr_data)

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(project.full_name, 42, described_class::PAID_ESCALATED_LABEL)
      end

      it "does not abort the restart when host label removal fails" do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error, "boom")

        expect(activity.send(:maybe_restart_draft, project, issue, pr_data)).to be(true)
        expect(issue.reload.pr_review_phase).to eq("restarted")
      end
    end

    context "when the PR does not carry the paid-escalated label" do
      let(:issue) do
        create(:issue, :pull_request,
          project: project,
          github_number: 42,
          pr_review_phase: "ready",
          labels: [ "paid-generated" ])
      end

      it "does not call GitHub to remove the label" do
        activity.send(:maybe_restart_draft, project, issue, pr_data)

        expect(github_client).not_to have_received(:remove_label_from_issue)
      end
    end
  end
end
