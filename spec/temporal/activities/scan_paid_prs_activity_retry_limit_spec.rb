# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanPaidPrsActivity do
  describe "#scan_pr retry-limit phase handling", :no_db do
    let(:activity) { described_class.new }
    let(:project) { instance_double(ProjectDouble) }
    let(:client) { instance_double(GithubClientDouble) }
    let(:progress_state) { instance_double(ProgressStateDouble) }
    let(:issue) do
      instance_double(IssueDouble,
        pr_review_phase: phase,
        id: 123,
        github_number: 42,
        review_goal_retry_count: 0,
        project: project)
    end

    before do
      stub_const("ProjectDouble", Class.new)
      stub_const("GithubClientDouble", Class.new)
      stub_const("ProgressStateDouble", Class.new)
      stub_const("IssueDouble", Class.new)
      stub_const("PrDataDouble", Class.new)

      allow(activity).to receive(:backfill_review_goal_retry_reset_at!).with(issue)
      allow(activity).to receive(:pr_progress_state).with(project, issue).and_return(progress_state)
      allow(activity).to receive(:record_focus_resolution).with(project, client, issue)
      allow(activity).to receive(:active_run_exists?).with(project, issue).and_return(false)
      allow(activity).to receive(:operational_failure_breaker?).with(project, issue, progress_state).and_return(false)
      allow(activity).to receive(:review_goal_retry_needed?).with(project, issue).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_reached?).with(project, issue).and_return(true)
      allow(activity).to receive(:review_goal_retry_limit_requires_escalation?).with(project, issue).and_return(true)
      allow(activity).to receive(:review_goal_consecutive_failure_count).with(project, issue).and_return(3)
      allow(activity).to receive(:check_rate_budget!).with(client)
      allow(activity).to receive(:fetch_pr_data)
      allow(activity).to receive(:escalate_trigger).and_return(:unexpected_escalation)
      allow(activity).to receive(:escalation_dismissed?).with(issue).and_return(false)
    end

    context "when the PR is still in draft" do
      let(:phase) { "draft" }

      it "still escalates immediately without fetching live PR state" do
        allow(activity).to receive(:escalate_trigger).with(issue,
          reason: "Review-goal retry limit reached (3 consecutive failures)").and_return(:escalated)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:escalated)
        expect(activity).not_to have_received(:fetch_pr_data)
      end
    end

    context "when the PR is ready and GitHub has converted it back to draft" do
      let(:phase) { "ready" }
      let(:pr_data) { instance_double(PrDataDouble, draft: true) }

      it "restarts the draft scan before considering escalation" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:maybe_restart_draft).with(project, issue, pr_data).and_return(true)
        allow(activity).to receive(:scan_draft_pr).with(project, client, issue, pr_data: pr_data).and_return(:draft_scan)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:draft_scan)
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end

    context "when the PR is ready and live PR data cannot be fetched" do
      let(:phase) { "ready" }

      it "skips instead of escalating on stale state" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(nil)
        allow(activity).to receive(:maybe_restart_draft).with(project, issue, nil).and_return(false)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:skipped)
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end

    context "when the PR is escalated and the escalation was dismissed" do
      let(:phase) { "escalated" }
      let(:pr_data) { instance_double(PrDataDouble, draft: false) }

      it "dismisses before any retry-limit escalation can fire" do
        allow(activity).to receive(:fetch_pr_data).with(client, project, issue).and_return(pr_data)
        allow(activity).to receive(:escalation_dismissed?).with(issue).and_return(true)
        allow(activity).to receive(:dismiss_escalation_trigger).with(issue, draft: false).and_return(:dismissed)

        result = activity.send(:scan_pr, project, client, issue)

        expect(result).to eq(:dismissed)
        expect(activity).not_to have_received(:escalate_trigger)
      end
    end
  end
end
