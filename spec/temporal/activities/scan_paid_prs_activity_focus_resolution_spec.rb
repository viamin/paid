# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanPaidPrsActivity do # @spec FOCUSED-RUN-002
  describe "#review_feedback_resolution_scores", :no_db do
    let(:activity) { described_class.new }
    let(:project) { instance_double(ProjectDouble) }
    let(:client) { instance_double(GithubClientDouble) }
    let(:issue) { instance_double(IssueDouble) }
    let(:focused_run) { instance_double(AgentRunDouble) }
    let(:pr_data) { instance_double(PrDataDouble) }
    let(:checks) { [ { name: "ci", conclusion: "success" } ] }
    let(:reviews) { [ { user_login: "paid-code-reviewer[bot]", state: "COMMENTED" } ] }
    let(:unresolved_threads) { [] }

    before do
      stub_const("ProjectDouble", Class.new)
      stub_const("GithubClientDouble", Class.new)
      stub_const("IssueDouble", Class.new)
      stub_const("AgentRunDouble", Class.new)
      stub_const("PrDataDouble", Class.new)
      allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
      allow(activity).to receive(:fetch_check_runs).with(client, project, pr_data).and_return(checks)
      allow(activity).to receive(:fetch_reviews).with(client, project, issue).and_return(reviews)
      allow(activity).to receive(:fetch_unresolved_threads).with(client, project, issue).and_return(unresolved_threads)
      allow(activity).to receive(:human_review_thread_triggers).with(project, unresolved_threads).and_return([])
      allow(activity).to receive(:check_non_enabled_bot_reviews)
        .with(reviews, unresolved_threads, project:, last_run: focused_run, client:, issue:)
        .and_return([])
      allow(activity).to receive(:changes_requested_from_reviews).with(project, reviews, focused_run).and_return([])
      allow(activity).to receive(:check_conversation_comments).with(client, project, issue, focused_run).and_return([])
      allow(activity).to receive(:non_bot_review_gate_triggers)
        .with(project, issue, pr_data, reviews, checks)
        .and_return([])
    end

    it "returns 0.0 when body-only review feedback is still pending" do
      allow(activity).to receive(:check_review_bot_status)
        .with(reviews, unresolved_threads, project:, last_run: focused_run, client:, issue:)
        .and_return([ { type: "review_bot_comments" } ])

      result = activity.send(:review_feedback_resolution_scores, project, client, issue, focused_run)

      expect(result).to eq("focus_resolved" => 0.0)
    end

    it "returns 1.0 when no review feedback signals remain" do
      allow(activity).to receive(:check_review_bot_status)
        .with(reviews, unresolved_threads, project:, last_run: focused_run, client:, issue:)
        .and_return([])

      result = activity.send(:review_feedback_resolution_scores, project, client, issue, focused_run)

      expect(result).to eq("focus_resolved" => 1.0)
    end

    it "defers attribution when required review data cannot be fetched" do
      allow(activity).to receive(:fetch_reviews).with(client, project, issue).and_return(nil)

      result = activity.send(:review_feedback_resolution_scores, project, client, issue, focused_run)

      expect(result).to be_nil
    end
  end
end
