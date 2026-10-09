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
    allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(dispatch_assessment)
    stub_dispatch_owner_create_issue
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

  def blank_title_followup_gap
    { "criterion" => "followup", "kind" => "agent", "title" => "", "body" => "" }
  end

  def stub_dispatch_owner_create_issue
    allow(client).to receive(:create_issue).and_return(OpenStruct.new(
      number: 99, html_url: "https://github.com/acme/alpha/issues/99", id: 99, title: "Wire dispatch", body: ""
    ))
    allow(Issues::UpsertFromGithub).to receive(:call).and_return(
      create(:issue, project: project, github_number: 99, github_state: "open")
    )
  end

  describe "#call" do
    # @spec PARTIAL-CLOSEOUT-018
    it "replays a legacy partial closeout with an empty reconciliation through Reconcile" do
      merged_pr(number: 10, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 10)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(1)
      expect(result.reconciled).to eq(1)
      expect(result.skipped).to eq(0)
      expect(result.lock_held).to be(false)
      expect(run.reload.reconciliation.fetch("status")).to eq("reconciled")
      expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(agent_run: run)
    end

    # @spec PARTIAL-CLOSEOUT-019 — stale gaps now completed: the assessment
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

    # @spec PARTIAL-CLOSEOUT-019 — unowned implementation work: the
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

    # @spec PARTIAL-CLOSEOUT-019 — human-only evidence: the assessment
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

    # @spec PARTIAL-CLOSEOUT-019 / @spec PARTIAL-CLOSEOUT-020 — replay
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

    # @spec PARTIAL-CLOSEOUT-020 — replay recovery for an interrupted
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

    # @spec PARTIAL-CLOSEOUT-020 — GitHub failure mid-reconciliation:
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

    # @spec PARTIAL-CLOSEOUT-018 — preserves terminal evidence: a run
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

    # @spec PARTIAL-CLOSEOUT-021 — scoped by account: a run from another
    # account is not touched by the sweep.
    it "scopes the candidate selection to the supplied account_id" do
      merged_pr(number: 18, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 18)
      other_account = create(:account)
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      described_class.call(account_id: other_account.id)

      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    end

    # @spec PARTIAL-CLOSEOUT-021 — bounds a single invocation's candidate
    # window so an account with many legacy runs cannot drive unbounded
    # `Llm::AnalyzePartialCloseout` cost/runtime in one call; `next_cursor`
    # lets a caller resume past the capped window and make forward
    # progress through the backlog regardless of each page's outcomes
    # (#4191 review).
    it "caps candidates per invocation via batch_size and resumes via next_cursor" do
      first_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 60)
      merged_pr(number: 50, parent_issue: first_issue)
      first_run = legacy_run(issue: first_issue, pull_request_number: 50)
      second_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 61)
      merged_pr(number: 51, parent_issue: second_issue)
      second_run = legacy_run(issue: second_issue, pull_request_number: 51)
      third_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 62)
      merged_pr(number: 52, parent_issue: third_issue)
      third_run = legacy_run(issue: third_issue, pull_request_number: 52)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

      first_page = described_class.call(account_id: account.id, batch_size: 2)

      expect(first_page.scanned).to eq(2)
      expect(first_page.next_cursor).to eq(second_run.id)
      expect(third_run.reload.reconciliation).to eq({})

      second_page = described_class.call(account_id: account.id, batch_size: 2, after_id: first_page.next_cursor)

      expect(second_page.scanned).to eq(1)
      expect(second_page.next_cursor).to eq(third_run.id)
      expect(first_run.reload.reconciliation.fetch("status")).to eq("reconciled")
      expect(third_run.reload.reconciliation.fetch("status")).to eq("reconciled")
    end

    # @spec PARTIAL-CLOSEOUT-021 — only an issue's latest PR-producing
    # attempt is assessable evidence: an older merged partial closeout must
    # not be replayed once a later `create_pr` attempt exists for the same
    # issue, or the sweep would file dependencies and operator notifications
    # from stale evidence the later attempt already superseded (#4191
    # review).
    it "skips a superseded earlier partial closeout when a later PR-producing attempt is terminal" do
      merged_pr(number: 31, parent_issue: parent)
      superseded_run = legacy_run(issue: parent, pull_request_number: 31)
      merged_pr(number: 32, parent_issue: parent)
      later_run = legacy_run(issue: parent, pull_request_number: 32,
        reconciliation: { "status" => "reconciled", "assessment" => { "gaps" => [] } })
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(1)
      expect(result.skipped).to eq(1)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
      expect(superseded_run.reload.reconciliation).to eq({})
      expect(later_run.reload.reconciliation.fetch("status")).to eq("reconciled")
    end

    # @spec PARTIAL-CLOSEOUT-021 — a later PR-producing attempt supersedes
    # the earlier merged partial closeout even before its own PR merges:
    # neither run is a candidate, so the sweep files nothing while the
    # later attempt's outcome is still pending (#4191 review).
    it "treats a later unmerged PR-producing attempt as superseding the earlier merged partial closeout" do
      merged_pr(number: 33, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 33)
      legacy_run(issue: parent, pull_request_number: 34)
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      result = described_class.call(account_id: account.id)

      expect(result.scanned).to eq(0)
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
    end

    # @spec PARTIAL-CLOSEOUT-021 — does not match a run whose PR number
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

    # @spec PARTIAL-CLOSEOUT-021 — a retryable_failure with a fresh
    # `failed_at` is inside the one-day retry gate: the sweep must skip
    # the run instead of re-invoking the LLM.
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

    # @spec PARTIAL-CLOSEOUT-021 — an explicit operator pause is a
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

    # @spec PARTIAL-CLOSEOUT-021 — needs_input is its own lane and
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

    # @spec PARTIAL-CLOSEOUT-020 — replay safety: the assessment is the
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

    # @spec PARTIAL-CLOSEOUT-020 — when a GitHub failure leaves a `creating`
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

    # @spec PARTIAL-CLOSEOUT-020 — the assessment is preserved across
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

    # @spec PARTIAL-CLOSEOUT-020 — replay wedge protection (anti-wedge):
    # an `ArgumentError` escaping `Reconcile.call` (e.g. an agent gap whose
    # `owner_issue_number` does not resolve to an open issue and whose
    # `title` is blank) must NOT propagate out of `process_run`. Without
    # a `rescue StandardError`, the `find_each` loop crashes, every
    # subsequent candidate is never scanned, and the persisted assessment
    # wedges every re-invocation at the same run (#4187 review thread).
    it "does not wedge the sweep when Reconcile raises a non-GitHub StandardError" do
      wedged_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 63)
      merged_pr(number: 27, parent_issue: wedged_issue)
      wedged_run = legacy_run(issue: wedged_issue, pull_request_number: 27)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).with(agent_run: wedged_run).and_return(
        "gaps" => [ { "criterion" => "unwired probe", "kind" => "agent", "owner_issue_number" => 999 } ]
      )

      tail_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 64)
      merged_pr(number: 28, parent_issue: tail_issue)
      tail_run = legacy_run(issue: tail_issue, pull_request_number: 28)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).with(agent_run: tail_run).and_return({ "gaps" => [] })

      result = nil
      expect { result = described_class.call(account_id: account.id) }.not_to raise_error

      expect(result.to_h).to include(scanned: 2, retryable_failure: 1, reconciled: 1)
      expect(tail_run.reload.reconciliation.fetch("status")).to eq("reconciled")
    end

    # @spec PARTIAL-CLOSEOUT-020 — replay wedge protection (assessment
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

    # @spec PARTIAL-CLOSEOUT-020 — replay wedge protection (assessment
    # preserved across partial progress): when a later gap in a multi-gap
    # assessment fails with a non-GitHub StandardError after an earlier
    # gap's owner was already recorded, the sweep must keep the persisted
    # assessment instead of discarding it. `prior_owner` and
    # `local_owner_with_marker` key owners by gap index, so discarding the
    # assessment while the surviving index-keyed `gaps` state remains would
    # let a regenerated (possibly reordered) assessment reattach the old
    # gap's owner to whichever gap now sits at that index (#4191 review).
    it "preserves the persisted assessment when gap state survives a later gap's non-GitHub failure" do
      merged_pr(number: 35, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 35)
      multi_gap_assessment = { "gaps" => [ dispatch_assessment["gaps"].first, blank_title_followup_gap ] }
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return(multi_gap_assessment)
      stub_dispatch_owner_create_issue

      result = described_class.call(account_id: account.id)

      expect(result.retryable_failure).to eq(1)
      reconciliation = run.reload.reconciliation
      expect(reconciliation.fetch("status")).to eq("retryable_failure")
      expect(reconciliation.fetch("error")).to include("agent gap title is required")
      expect(reconciliation.fetch("assessment")).to eq(multi_gap_assessment)
      expect(reconciliation.dig("gaps", "0", "owner_issue_number")).to eq(99)
    end

    # @spec PARTIAL-CLOSEOUT-020 — an `AgentHarness::Error` raised before
    # any assessment exists must persist `status`/`error`/`failed_at` on
    # the run: an unpersisted failure leaves an empty reconciliation
    # record, so the next invocation would immediately re-invoke the LLM
    # instead of honoring the one-day retry gate in
    # `legacy_reconciliation_already_done?` (#4191 review).
    it "persists a retryable failure when the assessment LLM call fails" do
      merged_pr(number: 30, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 30)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_raise(AgentHarness::Error, "provider unavailable")

      result = described_class.call(account_id: account.id)

      expect(result.retryable_failure).to eq(1)
      reconciliation = run.reload.reconciliation
      expect(reconciliation.fetch("status")).to eq("retryable_failure")
      expect(reconciliation.fetch("error")).to eq("provider unavailable")
      expect(reconciliation.fetch("failed_at")).to be_present
      expect(reconciliation).not_to have_key("assessment")

      # The persisted failure arms the one-day retry gate: an immediate
      # second sweep must not re-invoke the LLM.
      described_class.call(account_id: account.id)
      expect(Llm::AnalyzePartialCloseout).to have_received(:call).with(agent_run: run).once
    end

    # @spec PARTIAL-CLOSEOUT-021 — a non-positive batch_size breaks the
    # bounded sweep's continuation contract (`limit(0)` scans nothing but
    # `scanned == batch_size` still suggests a continuation whose cursor
    # never advances), so the service rejects it before scanning (#4191
    # review).
    it "rejects a non-positive batch_size" do
      expect { described_class.call(account_id: account.id, batch_size: 0) }
        .to raise_error(ArgumentError, /positive integer/)
      expect { described_class.call(account_id: account.id, batch_size: -1) }
        .to raise_error(ArgumentError, /positive integer/)
    end

    # @spec PARTIAL-CLOSEOUT-021 — concurrency: the operator console / MCP
    # surface and the rake task can both invoke this sweep for the same
    # account. Without serialization both would observe a blank
    # reconciliation, both call the LLM, and `Reconcile#create_owner!`
    # would see `creation_was_recorded?` as false in both, filing two owner
    # issues with the same marker (#4191 review).
    it "skips the sweep and makes no progress when another invocation holds the account's advisory lock" do
      merged_pr(number: 40, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 40)
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      # A genuinely separate PG session is required here: RSpec's
      # transactional fixtures pin every connection *checked out on this
      # thread* — including `ActiveRecord::Base.connection_pool.checkout` —
      # to the same backend/session, so advisory locks taken that way would
      # just re-enter the lock this example's own thread already holds.
      # Session-scoped `pg_try_advisory_lock` only contends across distinct
      # backends, so simulate the "other process" with a raw `pg` connection.
      db_config = ActiveRecord::Base.connection_db_config.configuration_hash
      other_session = PG.connect(
        host: db_config[:host], port: db_config[:port], dbname: db_config[:database],
        user: db_config[:username], password: db_config[:password]
      )
      begin
        other_session.exec_params(
          "SELECT pg_try_advisory_lock($1, $2)",
          [ PartialCloseouts::ReconcileLegacy::ADVISORY_LOCK_NAMESPACE, account.id ]
        )

        result = described_class.call(account_id: account.id)

        expect(result).to have_attributes(scanned: 0, lock_held: true)
        expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
        expect(run.reload.reconciliation).to eq({})
      ensure
        other_session.close
      end
    end

    it "releases the advisory lock after the sweep so a later invocation can proceed" do
      merged_pr(number: 41, parent_issue: parent)
      legacy_run(issue: parent, pull_request_number: 41)
      allow(Llm::AnalyzePartialCloseout).to receive(:call).and_return({ "gaps" => [] })

      described_class.call(account_id: account.id)
      second_result = described_class.call(account_id: account.id)

      expect(second_result.scanned).to eq(1)
    end
  end

  describe "#preview" do
    # @spec PARTIAL-CLOSEOUT-021 — the dry-run path the rake task uses to
    # show candidates before an operator opts into a sweep that files
    # GitHub issues and rewrites issue bodies (#4191 review).
    it "lists the candidate runs without invoking the LLM, Reconcile, or GitHub" do
      merged_pr(number: 42, parent_issue: parent)
      run = legacy_run(issue: parent, pull_request_number: 42)
      allow(Llm::AnalyzePartialCloseout).to receive(:call)

      candidates = described_class.new(account_id: account.id).preview

      expect(candidates).to contain_exactly(
        PartialCloseouts::ReconcileLegacy::CandidateRun.new(id: run.id, issue_id: parent.id)
      )
      expect(Llm::AnalyzePartialCloseout).not_to have_received(:call)
      expect(client).not_to have_received(:create_issue)
      expect(run.reload.reconciliation).to eq({})
    end

    it "respects batch_size and after_id the same way #call does" do
      first_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 70)
      merged_pr(number: 60, parent_issue: first_issue)
      first_run = legacy_run(issue: first_issue, pull_request_number: 60)
      second_issue = create(:issue, :in_progress, project: project, github_state: "open", github_number: 71)
      merged_pr(number: 61, parent_issue: second_issue)
      legacy_run(issue: second_issue, pull_request_number: 61)

      candidates = described_class.new(account_id: account.id, batch_size: 1).preview

      expect(candidates.map(&:id)).to eq([ first_run.id ])
    end
  end
end
