# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::MarkEscalatedActivity do
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:add_comment)
    allow(github_client).to receive(:remove_label_from_issue)
    allow(github_client).to receive(:recent_issue_comments).and_return([])
  end

  describe "#execute" do
    context "when issue exists" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft",
          draft_review_count: 3)
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "updates pr_review_phase to escalated" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "adds the paid-escalated label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end

      it "posts an escalation comment" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(issue.project.full_name, issue.github_number, a_string_including("Escalation Note"))
      end

      it "includes the default reason when no reason is provided" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("automated draft review limit"))
      end

      it "includes resolution instructions in the escalation comment" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("**How to resolve:**"))
      end

      it "mentions the owner in the escalation comment" do
        issue.project.update!(owner_reviewer_login: "viamin")

        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("@viamin"))
      end

      it "includes the remove-label instruction" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("Remove the `paid-escalated` label"))
      end

      it "includes the hidden comment marker for future identification" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("<!-- paid:escalation-note -->"))
      end

      it "uses a custom reason when provided" do
        activity.execute(issue_id: issue.id, reason: "Draft review limit reached")

        expect(github_client).to have_received(:add_comment)
          .with(anything, anything, a_string_including("Draft review limit reached"))
      end

      it "skips posting when an escalation comment already exists" do
        existing = OpenStruct.new(body: "<!-- paid:escalation-note -->\n**Escalation Note**")
        allow(github_client).to receive(:recent_issue_comments).and_return([ existing ])

        activity.execute(issue_id: issue.id)

        expect(github_client).not_to have_received(:add_comment)
      end

      it "returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end

      it "records an escalation decision event" do
        expect {
          activity.execute(issue_id: issue.id, reason: "Draft review limit reached")
        }.to change(OrchestrationDecision, :count).by(1)

        event = OrchestrationDecision.last
        expect(event.decision_type).to eq("escalate")
        expect(event.context["decision_status"]).to eq("applied")
        expect(event.inputs).to include("reason" => "Draft review limit reached")
      end
    end

    context "when label addition fails" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
          .and_raise(GithubClient::Error, "Not found")
      end

      it "still updates the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "still returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when comment posting fails" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "draft")
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
        allow(github_client).to receive(:add_comment)
          .and_raise(GithubClient::Error, "API error")
      end

      it "still updates the phase" do
        activity.execute(issue_id: issue.id)

        expect(issue.reload.pr_review_phase).to eq("escalated")
      end

      it "still adds the label" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end

      it "still returns updated: true" do
        result = activity.execute(issue_id: issue.id)

        expect(result[:updated]).to be true
      end
    end

    context "when issue carries the paid-ready label" do
      let(:issue) do
        create(:issue, :pull_request,
          pr_review_phase: "ready",
          labels: [ "paid-generated", "paid-automation", "paid-ready" ])
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "removes the paid-ready label so the label reflects the escalated state" do
        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:remove_label_from_issue)
          .with(issue.project.full_name, issue.github_number, "paid-ready")
      end

      it "still adds paid-escalated even if removing paid-ready fails" do
        allow(github_client).to receive(:remove_label_from_issue)
          .and_raise(GithubClient::Error, "transient")

        activity.execute(issue_id: issue.id)

        expect(github_client).to have_received(:add_labels_to_issue)
          .with(issue.project.full_name, issue.github_number, [ "paid-escalated" ])
      end
    end

    context "when issue does not carry the paid-ready label" do
      let(:issue) do
        create(:issue, :pull_request, pr_review_phase: "draft", labels: [ "paid-automation" ])
      end

      before do
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "does not call remove_label_from_issue for paid-ready" do
        activity.execute(issue_id: issue.id)

        expect(github_client).not_to have_received(:remove_label_from_issue)
          .with(anything, anything, "paid-ready")
      end
    end

    context "when issue is missing" do
      it "returns updated: false" do
        result = activity.execute(issue_id: -1)

        expect(result[:updated]).to be false
      end
    end
  end
end
