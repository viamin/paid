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

# @spec PARTIAL-CLOSEOUT-021
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
    ENV.delete("BATCH_SIZE")
    ENV.delete("AFTER_ID")
    ENV.delete("DRY_RUN")
  end

  it "raises a clear error when ACCOUNT_ID is not supplied" do
    ENV.delete("ACCOUNT_ID")

    expect { task.invoke }.to raise_error(KeyError)
  end

  # @spec PARTIAL-CLOSEOUT-021 — mirrors reset_false_positive_recommend_close
  # and repair_pull_request_source_links: default to a dry run that only
  # lists candidates, so a misscoped ACCOUNT_ID can't mutate a live repo
  # before an operator sees what would be touched (#4191 review).
  it "defaults to DRY_RUN and previews candidates without invoking the LLM or GitHub" do
    issue = create(:issue, :in_progress, project: project, github_state: "open")
    pull_request = create(:issue, :pull_request, project: project, github_number: 99,
      github_state: "closed", pr_review_phase: "merged", parent_issue: issue,
      github_html_url: "https://github.com/acme/alpha/pull/99")
    run = create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr",
      pull_request_number: 99, pull_request_url: pull_request.github_html_url, completed_at: 2.hours.ago)
    allow(Llm::AnalyzePartialCloseout).to receive(:call)

    expect { task.invoke }.to output(
      /DRY_RUN=true.*scanned:\s+1.*run=#{run.id} issue_id=#{issue.id}.*Dry run only/m
    ).to_stdout

    expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    expect(client).not_to have_received(:create_issue)
    expect(run.reload.reconciliation).to eq({})
  end

  it "does not invoke ReconcileLegacy.call while DRY_RUN is true" do
    allow(PartialCloseouts::ReconcileLegacy).to receive(:call)

    task.invoke

    expect(PartialCloseouts::ReconcileLegacy).not_to have_received(:call)
  end

  context "with DRY_RUN=false" do
    before { ENV["DRY_RUN"] = "false" }

    it "prints a result summary for a sweep that finds zero candidates" do
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call)
        .with(account_id: account.id, batch_size: PartialCloseouts::ReconcileLegacy::DEFAULT_BATCH_SIZE, after_id: nil)
        .and_return(
          PartialCloseouts::ReconcileLegacy::Result.new(
            scanned: 0, reconciled: 0, awaiting_operator: 0,
            retryable_failure: 0, skipped: 0, next_cursor: nil
          )
        )

      expect { task.invoke }.to output(
        /scanned:\s+0.*reconciled:\s+0.*awaiting_operator:\s+0.*retryable_failure:\s+0.*skipped:\s+0.*next_cursor:\s*$/m
      ).to_stdout
    end

    it "reports when another reconciliation holds the account lock" do
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call)
        .and_return(
          PartialCloseouts::ReconcileLegacy::Result.new(
            scanned: 0, reconciled: 0, awaiting_operator: 0,
            retryable_failure: 0, skipped: 0, next_cursor: nil, lock_held: true
          )
        )

      expect { task.invoke }.to output(
        /Another reconciliation for account #{account.id} is in progress; no work was done\. Re-run later\./
      ).to_stdout
    end

    it "invokes ReconcileLegacy exactly once with the parsed ACCOUNT_ID and default batch_size" do
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call)
        .and_return(
          PartialCloseouts::ReconcileLegacy::Result.new(
            scanned: 0, reconciled: 0, awaiting_operator: 0,
            retryable_failure: 0, skipped: 0, next_cursor: nil
          )
        )

      task.invoke

      expect(PartialCloseouts::ReconcileLegacy).to have_received(:call).with(
        account_id: account.id, batch_size: PartialCloseouts::ReconcileLegacy::DEFAULT_BATCH_SIZE, after_id: nil
      ).once
    end

    # @spec PARTIAL-CLOSEOUT-021 — BATCH_SIZE/AFTER_ID let an operator bound
    # a single invocation and resume a capped sweep across invocations
    # (#4191 review).
    it "passes BATCH_SIZE and AFTER_ID through to ReconcileLegacy and prompts to continue when the batch filled" do
      ENV["BATCH_SIZE"] = "2"
      ENV["AFTER_ID"] = "41"
      allow(PartialCloseouts::ReconcileLegacy).to receive(:call)
        .with(account_id: account.id, batch_size: 2, after_id: 41)
        .and_return(
          PartialCloseouts::ReconcileLegacy::Result.new(
            scanned: 2, reconciled: 2, awaiting_operator: 0,
            retryable_failure: 0, skipped: 0, next_cursor: 43
          )
        )

      expect { task.invoke }.to output(/More candidates may remain — re-run with AFTER_ID=43/).to_stdout
    end
  end

  # @spec PARTIAL-CLOSEOUT-021 — BATCH_SIZE=0 (or negative) scans nothing
  # while `scanned == batch_size` would still print an AFTER_ID
  # continuation whose cursor never advances, so the task rejects the
  # value before invoking the service (#4191 review).
  it "aborts when BATCH_SIZE is zero" do
    ENV["BATCH_SIZE"] = "0"
    allow(PartialCloseouts::ReconcileLegacy).to receive(:call)

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(/BATCH_SIZE must be a positive integer/).to_stderr
    expect(PartialCloseouts::ReconcileLegacy).not_to have_received(:call)
  end

  it "aborts when BATCH_SIZE is negative" do
    ENV["BATCH_SIZE"] = "-5"
    allow(PartialCloseouts::ReconcileLegacy).to receive(:call)

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(/BATCH_SIZE must be a positive integer/).to_stderr
    expect(PartialCloseouts::ReconcileLegacy).not_to have_received(:call)
  end
end

# @spec GITHUB-SYNC-016 PARTIAL-CLOSEOUT-038
RSpec.describe "issues:repair_premature_recommend_close" do
  let(:task) { Rake::Task["issues:repair_premature_recommend_close"] }
  let(:project) { create(:project, label_mappings: {}) }
  let(:client) { instance_double(GithubClient) }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("issues:repair_premature_recommend_close")
    task.reenable
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:remove_label_from_issue)
  end

  after { ENV.delete("DRY_RUN") }

  def create_mislabeled_issue(number:)
    issue = create(:issue, project: project, github_number: number, github_state: "open",
      paid_state: "recommend_close", labels: [ "paid-recommend-close" ])
    run = create(:agent_run, :completed, project: project, issue: issue,
      goal: "create_pr", pull_request_number: number + 1000)
    create(:issue, :pull_request, :closed, project: project, github_number: number + 1000,
      body: "Tracks ##{number}", pr_review_phase: "merged")
    [ issue, run ]
  end

  it "reports a candidate without writing changes in DRY_RUN (default)" do
    issue, run = create_mislabeled_issue(number: 3441)

    expect { task.invoke }.to output(/##{issue.github_number}.*run=#{run.id}/).to_stdout

    expect(issue.reload.paid_state).to eq("recommend_close")
    expect(client).not_to have_received(:remove_label_from_issue)
  end

  it "skips an issue with a current, fresh close disposition from an acceptance audit" do
    issue, = create_mislabeled_issue(number: 3441)
    request = create(:issue_continuation_request, issue: issue, project: project,
      evidence: { "continuation_mode" => "acceptance_audit" })
    create(:agent_run, :completed, project: project, issue: issue, goal: "analyze_issue",
      continuation_request: request,
      reconciliation: { "assessment" => {
                           "criteria" => [ { "criterion" => "live validation", "state" => "satisfied" } ],
                           "gaps" => [],
                           "source_revision" => Issues::CloseoutEvidence.call(issue).digest,
                           "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
                           "assessed_at" => Time.current.iso8601
                         },
                         "source_closure" => { "disposition" => "close" } })

    expect { task.invoke }.to output(/Found 0 issue/).to_stdout
  end

  it "leaves a recommend_close issue alone when its PR actually carries a closing reference" do
    issue = create(:issue, project: project, github_state: "open", github_number: 20,
      paid_state: "recommend_close", labels: [ "paid-recommend-close" ])
    create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr", pull_request_number: 1020)
    create(:issue, :pull_request, :closed, project: project, github_number: 1020,
      body: "Closes #20", pr_review_phase: "merged")

    expect { task.invoke }.to output(/Found 0 issue/).to_stdout
    expect(issue.reload.paid_state).to eq("recommend_close")
  end

  context "with DRY_RUN=false" do
    before { ENV["DRY_RUN"] = "false" }

    it "reverts the issue to completed and removes the GitHub label" do
      issue, = create_mislabeled_issue(number: 3441)

      task.invoke

      expect(issue.reload.paid_state).to eq("completed")
      expect(client).to have_received(:remove_label_from_issue).with(project.full_name, issue.github_number, "paid-recommend-close")
    end

    it "logs and continues when the GitHub label removal fails" do
      issue, = create_mislabeled_issue(number: 3441)
      allow(client).to receive(:remove_label_from_issue).and_raise(GithubClient::Error.new("temporary failure"))

      expect { task.invoke }.to output(/label removal failed for ##{issue.github_number}/).to_stdout

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "is idempotent on a repeated invocation" do
      issue, = create_mislabeled_issue(number: 3441)
      task.invoke
      task.reenable

      expect { task.invoke }.to output(/Found 0 issue/).to_stdout
      expect(issue.reload.paid_state).to eq("completed")
    end
  end
end

# rubocop:enable RSpec/DescribeClass, RSpec/MultipleDescribes
