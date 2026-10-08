# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe PartialCloseouts::ReconcileLegacy do
  let(:account) { create(:account) }
  let(:project) do
    create(
      :project,
      account: account,
      auto_pick_enabled: true,
      active: true,
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:client) { instance_double(GithubClient) }
  let(:parent) { create(:issue, :in_progress, project: project, github_state: "open") }
  let(:dispatch_synced_issue) do
    create(:issue, project: project, github_number: 25, github_state: "open")
  end

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:update_issue)
    allow(client).to receive(:issue) { OpenStruct.new(body: parent.body.to_s) }
    allow(client).to receive(:create_issue)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:remove_label_from_issue)
  end

  def legacy_run(issue:, pull_request_number: 1, completed_at: 2.hours.ago, reconciliation: {}, pull_request_url: nil)
    create(
      :agent_run,
      :completed,
      project: project,
      issue: issue,
      goal: "create_pr",
      pull_request_number: pull_request_number,
      pull_request_url: pull_request_url || "https://github.com/acme/alpha/pull/#{pull_request_number}",
      completed_at: completed_at,
      reconciliation: reconciliation
    )
  end

  def merged_pr(number:, parent_issue:, html_url: "https://github.com/acme/alpha/pull/#{number}", **attrs)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue: parent_issue,
      github_html_url: html_url,
      **attrs
    )
  end

  def stub_marker_recovery(marker, remote_issue, synced)
    allow(client).to receive(:search_issues)
      .with(%(repo:#{project.full_name} is:issue state:open in:body "#{marker}"), per_page: 100)
      .and_return(OpenStruct.new(items: [ remote_issue ]))
    allow(Issues::UpsertFromGithub).to receive(:call).with(project:, github_issue: remote_issue).and_return(synced)
  end

  def dispatch_assessment
    { "gaps" => [ { "criterion" => "dispatch", "kind" => "agent",
      "title" => "Wire dispatch", "body" => "Wire the dispatch worker." } ] }
  end

  def followup_assessment
    { "gaps" => [ { "criterion" => "followup", "kind" => "agent",
      "title" => "Follow-up", "body" => "Capture the follow-up work." } ] }
  end

  def dispatch_remote_issue(marker)
    OpenStruct.new(
      number: 25, html_url: "https://github.com/acme/alpha/issues/25",
      id: 25, title: "Wire dispatch",
      body: "Wire dispatch\n\n#{marker}"
    )
  end

  def stub_dispatch_assessment_with_create_issue
    synced = create(:issue, project: project, github_number: 99, github_state: "open")
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(dispatch_assessment)
    allow(client).to receive(:create_issue).and_return(OpenStruct.new(
      number: 99, html_url: "https://github.com/acme/alpha/issues/99",
      id: 99, title: "Wire dispatch", body: ""
    ))
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(synced)
  end

  def stale_creating_reconciliation(marker)
    {
      "status" => "retryable_failure",
      "error" => "github unavailable",
      "failed_at" => 2.days.ago.iso8601,
      "gaps" => { "0" => { "status" => "creating", "marker" => marker } },
      "assessment" => dispatch_assessment
    }
  end

  def stub_github_create_issue_failure
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(dispatch_assessment)
    allow(client).to receive(:create_issue).and_raise(GithubClient::Error, "github unavailable")
  end

  describe "#call" do
    # @spec PARTIAL-CLOSEOUT-012
    it "replays a legacy partial closeout with an empty reconciliation through Reconcile" do
      merged_pr(number: 10, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 10)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(1)
      expect(result.reconciled).to eq(1)
      expect(result.skipped).to eq(0)
      expect(run.reload.reconciliation.fetch("status")).to eq("reconciled")
      expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(agent_run: run)
    end

    # @spec PARTIAL-CLOSEOUT-013 — stale gaps now completed: the assessment
    # returns zero gaps because the LLM grounds its decision in current
    # evidence, and the sweep records status=reconciled with no new owners.
    it "records zero-gap legacy reconciliation without creating owners" do
      merged_pr(number: 11, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 11)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

      result = described_class.call(account_id: account.id)

      expect(result.reconciled).to eq(1)
      expect(client).not_to have_received(:create_issue)
      expect(IssueDependency.where(issue: parent)).to be_empty
    end

    # @spec PARTIAL-CLOSEOUT-013 — unowned implementation work: the
    # assessment includes a gap with no `owner_issue_number`, and the
    # sweep files a focused follow-up through the existing owner-creation
    # path.
    it "files a focused follow-up issue for an unowned implementation gap" do
      merged_pr(number: 12, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 12)
      created = OpenStruct.new(number: 99, html_url: "https://github.com/acme/alpha/issues/99",
        id: 99, title: "Wire dispatch", body: "")
      allow(client).to receive(:create_issue).and_return(created)
      allow(Issues::UpsertFromGithub).to receive(:call).and_return(
        create(:issue, project: project, github_number: 99, github_state: "open")
      )
      assessment = { "gaps" => [ { "criterion" => "dispatch", "kind" => "agent",
        "title" => "Wire dispatch", "body" => "Wire the dispatch worker" } ] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = described_class.call(account_id: account.id)

      expect(result.reconciled).to eq(1)
      expect(client).to have_received(:create_issue).with(
        project.full_name,
        hash_including(title: "Wire dispatch")
      )
      owner = project.issues.find_by(github_number: 99)
      expect(parent.reload.issue_dependencies.find_by(depends_on_issue: owner)).to be_present
    end

    # @spec PARTIAL-CLOSEOUT-013 — human-only evidence: the assessment
    # carries a `human` gap with its exact `next_step`, and the sweep
    # publishes one aggregated blocking Inbox notification under
    # PREREQUISITE_NOTIFICATION_SOURCE.
    it "publishes a blocking Inbox notification for a human prerequisite" do
      merged_pr(number: 13, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 13)
      assessment = { "gaps" => [ { "criterion" => "macOS acceptance", "kind" => "human",
        "next_step" => "Run the approved macOS pilot." } ] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(assessment)

      result = described_class.call(account_id: account.id)

      expect(result.awaiting_operator).to eq(1)
      notification = Notification.where(subject: parent, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE).last
      expect(notification).to be_present
      expect(notification.blocking).to be(true)
      expect(notification.title).to eq("macOS acceptance needs operator action")
    end

    # @spec PARTIAL-CLOSEOUT-013 / @spec PARTIAL-CLOSEOUT-014 — replay
    # recovery: re-running the sweep on a run already marked terminal must
    # NOT re-invoke the analyzer, must NOT re-file owners, must NOT publish
    # duplicate notifications.
    it "does not duplicate owners or notifications on a repeated sweep" do
      merged_pr(number: 14, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 14,
        reconciliation: { "status" => "reconciled", "assessment" => { "gaps" => [] } })

      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(1)
      expect(result.reconciled).to eq(0)
      expect(result.skipped).to eq(1)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    end

    # @spec PARTIAL-CLOSEOUT-014 — replay recovery for an interrupted
    # attempt: a prior pass left a `creating` marker for a gap, and the
    # second pass resumes owner recovery through the existing
    # `recovered_remote_owner` path instead of filing a second issue.
    it "resumes a `creating` legacy attempt via the marker-based owner recovery" do
      merged_pr(number: 15, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 15)
      marker = "<!-- paid:partial-closeout:#{run.id}:0 -->"
      run.update!(reconciliation: { "status" => "reconciling",
        "gaps" => { "0" => { "status" => "creating", "marker" => marker } } })
      remote_issue = OpenStruct.new(
        number: 18, html_url: "https://github.com/acme/alpha/issues/18",
        id: 18, title: "Wire dispatch",
        body: "Wire dispatch\n\n#{marker}"
      )
      synced = create(:issue, project: project, github_number: 18, github_state: "open")
      stub_marker_recovery(marker, remote_issue, synced)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(
        { "gaps" => [ { "criterion" => "dispatch", "kind" => "agent", "title" => "Wire dispatch", "body" => "" } ] }
      )

      result = described_class.call(account_id: account.id)

      expect(result.reconciled).to eq(1)
      expect(client).not_to have_received(:create_issue)
      expect(parent.reload.issue_dependencies.find_by(depends_on_issue: synced)).to be_present
    end

    # @spec PARTIAL-CLOSEOUT-014 — GitHub failure mid-reconciliation:
    # a `GithubClient::Error` after a partial create leaves the run's
    # `reconciliation.status` as `retryable_failure` and the `error` /
    # `failed_at` fields populated, so the next sweep can retry without
    # re-filing the owner.
    it "records a retryable failure when a GitHub error interrupts reconciliation" do
      merged_pr(number: 16, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 16)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(
        { "gaps" => [ { "criterion" => "dispatch", "kind" => "agent", "title" => "Wire dispatch", "body" => "Wire" } ] }
      )
      allow(client).to receive(:create_issue).and_raise(GithubClient::Error, "github unavailable")

      result = described_class.call(account_id: account.id)

      expect(result.retryable_failure).to eq(1)
      expect(run.reload.reconciliation.fetch("status")).to eq("retryable_failure")
      expect(run.reconciliation.fetch("error")).to eq("github unavailable")
    end

    # @spec PARTIAL-CLOSEOUT-012 — preserves terminal evidence: a run
    # whose partial PR already linked to a no-code-required outcome on
    # the issue must NOT mass-reset paid_state or auto-close the issue.
    it "does not reset paid_state or close the umbrella while reconciling a legacy partial closeout" do
      merged_pr(number: 17, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 17)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

      original_paid_state = parent.paid_state
      original_state = parent.github_state

      described_class.call(account_id: account.id)

      expect(parent.reload.paid_state).to eq(original_paid_state)
      expect(parent.github_state).to eq(original_state)
    end

    # @spec PARTIAL-CLOSEOUT-015 — scoped by account: a run from another
    # account is not touched by the sweep.
    it "scopes the candidate selection to the supplied account_id" do
      merged_pr(number: 18, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 18)
      other_account = create(:account)
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      described_class.call(account_id: other_account.id)

      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    end

    # @spec PARTIAL-CLOSEOUT-015 — does not match a run whose PR number
    # only collides with an upstream-synced PR (no parent_issue_id and
    # a different URL).
    it "does not treat a number-colliding upstream PR as terminal evidence for a legacy run" do
      upstream = create(
        :issue, :pull_request,
        project: project,
        github_number: 19,
        github_state: "closed",
        pr_review_phase: "merged",
        source: Issue::UPSTREAM_PULL_REQUEST_SOURCE,
        github_html_url: "https://github.com/upstream/repo/pull/19"
      )
      # Force parent_issue_id off and use a fork URL on the run so the
      # URL fallback does not match the upstream PR.
      upstream.update_columns(parent_issue_id: nil)
      legacy_run(
        issue: parent,
        pull_request_number: 19,
        pull_request_url: "https://github.com/acme/alpha/pull/19"
      )
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(0)
    end

    # @spec PARTIAL-CLOSEOUT-015 — the assessment is reused across
    # repeated sweeps that find the run still in `reconciling` state.
    it "skips a run whose stale retryable_failure is within the recent window" do
      merged_pr(number: 20, parent_issue: parent)
      run = legacy_run(
        issue: parent,
        pull_request_number: 20,
        reconciliation: { "status" => "retryable_failure", "error" => "github unavailable", "failed_at" => 1.minute.ago.iso8601 }
      )
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.skipped).to eq(1)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
      expect(run.reload.reconciliation.fetch("status")).to eq("retryable_failure")
    end

    # @spec PARTIAL-CLOSEOUT-015 — an explicit operator pause is a
    # deliberate hold, not a stall: the sweep must NOT touch the run's
    # reconciliation when its issue is paused.
    it "skips a legacy run whose issue is paused" do
      merged_pr(number: 21, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 21)
      parent.update!(paused: true)
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(1)
      expect(result.skipped).to eq(1)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    end

    # @spec PARTIAL-CLOSEOUT-015 — needs_input is its own lane and
    # should not be touched by legacy reconciliation.
    it "skips a legacy run whose issue is in needs_input" do
      merged_pr(number: 22, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 22)
      parent.update!(paid_state: "needs_input")
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(1)
      expect(result.skipped).to eq(1)
    end

    # @spec PARTIAL-CLOSEOUT-014 — replay safety: the assessment is the
    # deterministic input that anchors retries, so the sweep must persist it
    # on the run before invoking `Reconcile` (mirrors
    # `Activities::ReconcilePartialCloseoutActivity#persisted_assessment`).
    it "persists the assessment on the run before invoking Reconcile" do
      merged_pr(number: 23, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 23)
      stub_dispatch_assessment_with_create_issue

      described_class.call(account_id: account.id)

      expect(run.reload.reconciliation.fetch("assessment")).to eq(dispatch_assessment)
    end

    # @spec PARTIAL-CLOSEOUT-014 — when a GitHub failure leaves a `creating`
    # marker and the retry window allows the next pass after one day, the
    # sweep must reuse the assessment already on the run instead of
    # re-invoking the LLM. A reordered re-invocation would attach the owner
    # created for the old index 0 to whichever gap now sits at index 0
    # (`Reconcile.create_owner!` keys `owner_marker` /
    # `creation_was_recorded?` by array index), producing an incorrect
    # dependency.
    it "reuses the persisted assessment after a stale retryable_failure instead of re-invoking the LLM" do
      merged_pr(number: 24, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 24)
      marker = "<!-- paid:partial-closeout:#{run.id}:0 -->"
      stub_marker_recovery(marker, dispatch_remote_issue(marker), dispatch_synced_issue)
      run.update!(reconciliation: stale_creating_reconciliation(marker))

      # If the sweep re-invokes the LLM, the reversed gap below attaches
      # the recovered remote owner (created for `dispatch`) to `followup`
      # instead. The persisted assessment must win.
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(followup_assessment)

      result = described_class.call(account_id: account.id)

      expect(result.reconciled).to eq(1)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
      expect(parent.reload.issue_dependencies.find_by(depends_on_issue: dispatch_synced_issue)).to be_present
    end

    # @spec PARTIAL-CLOSEOUT-014 — the assessment is preserved across
    # `record_failure!` so a failed first sweep leaves the next pass with
    # everything it needs to resume through the marker-based recovery path
    # without re-invoking the LLM.
    it "preserves the persisted assessment across a GitHub failure so the retry can resume without a new LLM call" do
      merged_pr(number: 26, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 26)
      stub_github_create_issue_failure

      described_class.call(account_id: account.id)

      reconciliation = run.reload.reconciliation
      expect(reconciliation.fetch("status")).to eq("retryable_failure")
      expect(reconciliation.fetch("assessment")).to eq(dispatch_assessment)
      expect(reconciliation.dig("gaps", "0", "marker")).to start_with("<!-- paid:partial-closeout:#{run.id}:0 -->")
    end

    # @spec PARTIAL-CLOSEOUT-014 — replay wedge protection (anti-wedge):
    # an `ArgumentError` escaping `Reconcile.call` (e.g. an agent gap whose
    # `owner_issue_number` does not resolve to an open issue and whose
    # `title` is blank) must NOT propagate out of `process_run`. Without
    # a `rescue StandardError`, the `find_each` loop crashes, every
    # subsequent candidate is never scanned, and the persisted assessment
    # wedges every re-invocation at the same run (#4187 review thread).
    it "does not wedge the sweep when Reconcile raises a non-GitHub StandardError" do
      merged_pr(number: 27, parent_issue: parent)
      wedged_run = legacy_run(issue: parent, pull_request_number: 27)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).with(agent_run: wedged_run).and_return(
        "gaps" => [ { "criterion" => "unwired probe", "kind" => "agent", "owner_issue_number" => 999 } ]
      )

      merged_pr(number: 28, parent_issue: parent)
      tail_run = legacy_run(issue: parent, pull_request_number: 28)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).with(agent_run: tail_run).and_return({ "gaps" => [] })

      result = nil
      expect { result = described_class.call(account_id: account.id) }.not_to raise_error

      expect(result.to_h).to include(scanned: 2, retryable_failure: 1, reconciled: 1)
      expect(tail_run.reload.reconciliation.fetch("status")).to eq("reconciled")
    end

    # @spec PARTIAL-CLOSEOUT-014 — replay wedge protection (assessment
    # discard): the non-GitHub path treats the assessment as deterministic-bad
    # (e.g. `Reconcile#create_owner!` raised `ArgumentError` because `title`
    # was blank) and discards `reconciliation.assessment` so the next pass
    # regenerates instead of replaying the same input forever. GitHub
    # failures above still preserve the assessment for replay through the
    # marker-based recovery path (#4187 review thread).
    it "discards the persisted assessment on a non-GitHub StandardError so the next pass regenerates" do
      merged_pr(number: 29, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 29)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(
        "gaps" => [ { "criterion" => "unwired probe", "kind" => "agent", "owner_issue_number" => 999 } ]
      )

      described_class.call(account_id: account.id)

      reconciliation = run.reload.reconciliation
      expect(reconciliation.fetch("status")).to eq("retryable_failure")
      expect(reconciliation.fetch("error")).to include("agent gap title is required")
      expect(reconciliation.fetch("failed_at")).to be_present
      expect(reconciliation).not_to have_key("assessment")
    end
  end
end
