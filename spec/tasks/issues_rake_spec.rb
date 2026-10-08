# frozen_string_literal: true

require "rails_helper"
require "rake"
require "ostruct"

# rubocop:disable RSpec/DescribeClass, RSpec/MultipleDescribes
RSpec.describe "issues:repair_pull_request_source_links" do
  let(:task) { Rake::Task["issues:repair_pull_request_source_links"] }
  let(:project) { create(:project) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("issues:repair_pull_request_source_links")
    task.reenable
    # The sandbox environment may already export PROJECT_ID; start each
    # example from an unscoped baseline unless it opts into scoping itself.
    ENV.delete("PROJECT_ID")
  end

  after do
    ENV.delete("DRY_RUN")
    ENV.delete("PROJECT_ID")
  end

  # @spec EAGER-QUEUE-009 EAGER-QUEUE-010
  it "reports a repair without writing changes in DRY_RUN (default)" do
    issue = create(:issue, project: project)
    create(:agent_run, :completed, :automatic, project: project, issue: issue,
      goal: "create_pr", pull_request_number: 4047, pull_request_url: "https://example.test/pr/4047")
    pull_request = create(:issue, :pull_request, project: project, github_number: 4047,
      github_state: "open", github_html_url: "https://example.test/pr/4047")

    expect { task.invoke }.to output(/PR #4047.*issue ##{issue.github_number}/).to_stdout

    expect(pull_request.reload.parent_issue_id).to be_nil
  end

  context "with DRY_RUN=false" do
    before { ENV["DRY_RUN"] = "false" }

    it "links an unambiguous PR back to its source issue" do
      issue = create(:issue, project: project)
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", pull_request_number: 4047, pull_request_url: "https://example.test/pr/4047")
      pull_request = create(:issue, :pull_request, project: project, github_number: 4047,
        github_state: "open", github_html_url: "https://example.test/pr/4047")

      task.invoke

      expect(pull_request.reload.parent_issue_id).to eq(issue.id)
    end

    it "leaves an ambiguous PR history unlinked and reports it" do
      first_issue = create(:issue, project: project, github_number: 1)
      second_issue = create(:issue, project: project, github_number: 2)
      create(:agent_run, :completed, project: project, issue: first_issue,
        goal: "create_pr", pull_request_number: 4047, pull_request_url: "https://example.test/pr/4047")
      create(:agent_run, :completed, project: project, issue: second_issue,
        goal: "create_pr", pull_request_number: 4047, pull_request_url: "https://example.test/pr/4047")
      pull_request = create(:issue, :pull_request, project: project, github_number: 4047,
        github_state: "open", github_html_url: "https://example.test/pr/4047")

      expect { task.invoke }.to output(/AMBIGUOUS PR #4047/).to_stdout

      expect(pull_request.reload.parent_issue_id).to be_nil
    end

    it "cancels a queued duplicate run the repair reveals as no longer eligible" do
      # Mirrors the #4052 incident: a completed run's PR outlived the
      # one-hour sync grace period before the link existed, so a second run
      # got queued for the same source issue.
      issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        github_number: 200_001_838, github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1838)
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 4047, pull_request_url: "https://example.test/pr/4047",
        completed_at: Automation::Strategies::AutoPick::DefaultCandidateSource::PR_SYNC_GRACE_PERIOD.ago - 1.minute)
      create(:issue, :pull_request, project: project, github_number: 4047,
        github_state: "open", github_html_url: "https://example.test/pr/4047")
      duplicate_run = create(:agent_run, :queued, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true)

      task.invoke

      expect(duplicate_run.reload.status).to eq("cancelled")
    end

    it "scopes the repair to PROJECT_ID when given" do
      ENV["PROJECT_ID"] = project.id.to_s
      other_project = create(:project)
      other_issue = create(:issue, project: other_project)
      create(:agent_run, :completed, project: other_project, issue: other_issue,
        goal: "create_pr", pull_request_number: 55, pull_request_url: "https://example.test/pr/55")
      other_pull_request = create(:issue, :pull_request, project: other_project, github_number: 55,
        github_state: "open", github_html_url: "https://example.test/pr/55")

      task.invoke

      expect(other_pull_request.reload.parent_issue_id).to be_nil
    end
  end
end

# @spec PARTIAL-CLOSEOUT-015
RSpec.describe "issues:reconcile_legacy_partial_closeouts" do
  let(:task) { Rake::Task["issues:reconcile_legacy_partial_closeouts"] }
  let(:account) { create(:account) }
  let(:project) do
    create(:project, account: account, owner: "acme", repo: "alpha")
  end
  let(:client) { instance_double(GithubClient) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("issues:reconcile_legacy_partial_closeouts")
    task.reenable
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:update_issue)
    allow(client).to receive(:issue).and_return(OpenStruct.new(body: ""))
    allow(client).to receive(:create_issue)
    ENV["ACCOUNT_ID"] = account.id.to_s
  end

  after do
    ENV.delete("ACCOUNT_ID")
  end

  it "raises a clear error when ACCOUNT_ID is not supplied" do
    ENV.delete("ACCOUNT_ID")

    expect { task.invoke }.to raise_error(KeyError)
  end

  it "prints a result summary for a sweep that finds zero candidates" do
    allow(PartialCloseouts::ReconcileLegacy).to receive(:call)
      .with(account_id: account.id).and_return(
        PartialCloseouts::ReconcileLegacy::Result.new(
          scanned: 0, reconciled: 0, awaiting_operator: 0,
          retryable_failure: 0, skipped: 0
        )
      )

    expect { task.invoke }.to output(
      /scanned:\s+0.*reconciled:\s+0.*awaiting_operator:\s+0.*retryable_failure:\s+0.*skipped:\s+0/m
    ).to_stdout
  end

  it "invokes ReconcileLegacy exactly once with the parsed ACCOUNT_ID" do
    allow(PartialCloseouts::ReconcileLegacy).to receive(:call)
      .and_return(
        PartialCloseouts::ReconcileLegacy::Result.new(
          scanned: 0, reconciled: 0, awaiting_operator: 0,
          retryable_failure: 0, skipped: 0
        )
      )

    task.invoke

    expect(PartialCloseouts::ReconcileLegacy).to have_received(:call).with(account_id: account.id).once
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/MultipleDescribes
