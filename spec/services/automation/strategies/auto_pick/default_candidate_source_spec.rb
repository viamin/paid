# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Strategies::AutoPick::DefaultCandidateSource do
  let(:project) { create(:project, auto_pick_enabled: true) }

  describe ".next_candidate" do
    it "returns the top-ranked eligible issue for the project" do
      issue = create(:issue, project: project, github_state: "open")

      expect(described_class.next_candidate(project)).to eq(issue)
    end

    it "returns nil when the project has no eligible candidates" do
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.next_candidate(project)).to be_nil
    end

    it "prefers higher-priority issues over lower-priority ones" do
      _p3 = create(:issue, project: project, github_number: 1, labels: [ "P3" ])
      p1 = create(:issue, project: project, github_number: 2, labels: [ "P1" ])

      expect(described_class.next_candidate(project)).to eq(p1)
    end

    it "matches configured priority labels case-insensitively" do
      project.update!(priority_labels: { "P1" => "P1", "P2" => "P2", "P3" => "P3" })
      _p3 = create(:issue, project: project, github_number: 1, labels: [ "p3" ])
      p1 = create(:issue, project: project, github_number: 2, labels: [ "p1" ])

      expect(described_class.next_candidate(project)).to eq(p1)
    end

    it "prefers runnable dependency-tree roots over standalone issues" do
      _standalone = create(:issue, project: project, github_number: 1, github_state: "open")
      blocker = create(:issue, project: project, github_number: 2, github_state: "open")
      dependent = create(:issue, project: project, github_number: 3, github_state: "open")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      expect(described_class.next_candidate(project)).to eq(blocker)
    end

    it "counts open dependents from other projects in the same account" do
      other_project = create(:project, account: project.account)
      _standalone = create(:issue, project: project, github_number: 1, github_state: "open")
      blocker = create(:issue, project: project, github_number: 2, github_state: "open")
      dependent = create(:issue, project: other_project, github_number: 3, github_state: "open")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      expect(described_class.next_candidate(project)).to eq(blocker)
    end

    it "does not penalize issues whose dependents are all closed" do
      former_blocker = create(:issue, project: project, github_number: 1, github_state: "open")
      _standalone = create(:issue, project: project, github_number: 2, github_state: "open")
      closed_dependent = create(:issue, project: project, github_number: 3, github_state: "closed")
      create(:issue_dependency, issue: closed_dependent, depends_on_issue: former_blocker)

      # former_blocker gets no dependency-tree boost once all dependents are closed.
      expect(described_class.next_candidate(project)).to eq(former_blocker)
    end
  end

  describe ".eligible_scope" do
    it "returns a scope limited to eligible issues" do
      eligible = create(:issue, project: project)
      create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "includes analyzed issues without requiring a follow-up backfill sweep" do
      issue = create(:issue, project: project, paid_state: "analyzed")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "excludes failed issues during an active analyze_issue provider-exhaustion cooldown" do
      issue = create(:issue, project: project, paid_state: "failed")
      travel 1.minute do
        issue.update!(
          issue_analysis_next_attempt_at: 10.minutes.from_now,
          issue_analysis_backoff_set_at: Time.current
        )

        scope = described_class.eligible_scope(project)

        expect(scope.pluck(:id)).to be_empty
      end
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "re-includes failed issues once the analyze_issue provider-exhaustion cooldown expires" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 1.minute.ago,
        issue_analysis_backoff_set_at: 11.minutes.ago)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when issue-analysis runner configuration changes" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)

      project.effective_owner.settings.update!(issue_analysis_runner: "codex")
      # log_data is written by a DB trigger, not the in-memory update!, so the
      # cached association needs a reload to see it — matching how a fresh
      # read in a separate process (the real auto-pick job) would observe it.
      project.effective_owner.settings.reload

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat unrelated user setting changes as resetting the cooldown" do
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)

      settings = project.effective_owner.settings
      theme = settings.theme_preference == "dark" ? "light" : "dark"
      settings.update!(theme_preference: theme)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when issue-analysis authentication changes" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      api_key = create(:provider_api_key, user: project.effective_owner, api_service_type: "anthropic")
      # The reset signal is scoped to provider API keys that back a
      # Runner record the chat-capable fallback set can actually attempt
      # (PR #3650 review discussion). Without this Runner, rotating the
      # api_key would be a no-op for issue analysis and must not reset.
      create(:runner, :api_key, user: project.effective_owner,
        runner_key: "claude", provider_api_key: api_key)

      api_key.update!(api_key: "sk-rotated-#{SecureRandom.hex(8)}")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat rotation of an unrelated provider api key as resetting the cooldown" do
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      # An api key not referenced by any chat-capable Runner record (the
      # default subscription "claude" Runner has provider_api_key_id: nil)
      # must not clear the cooldown — its rotation cannot change which
      # providers issue analysis can attempt.
      api_key = create(:provider_api_key, user: project.effective_owner, api_service_type: "openai")

      api_key.update!(api_key: "sk-rotated-#{SecureRandom.hex(8)}")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat routine runner weight rebalancing as resetting the cooldown" do
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      runner = create(:runner, user: project.effective_owner, runner_key: "cursor")

      runner.update!(weight: runner.weight + 1)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when a runner is enabled or disabled for agent runs" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      create(:runner, user: project.effective_owner, runner_key: "cursor")
      runner = create(:runner, user: project.effective_owner, runner_key: "codex")

      runner.update!(enabled_for_agent_runs: false)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when a chat-capable runner is discarded" do
      # Discard is the strongest user signal that the exhausted runner
      # configuration has changed — scanning log_data on the discarded row
      # must observe the `discarded_at` version even though the row is no
      # longer in `kept_only`. Pin the runner via `issue_analysis_runner`
      # so the `runner_key` bound in `relevant_runners` still includes the
      # discarded row (the configured key stays in
      # `configured_issue_analysis_runner_keys` after discard). Discarding
      # an unconfigured chat-capable runner has no effect on the cooldown
      # because the runtime would never have attempted that runner anyway.
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      settings = project.effective_owner.settings
      settings.update!(issue_analysis_runner: "codex")
      runner = create(:runner, user: project.effective_owner, runner_key: "codex")

      runner.discard!

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat routine runner quota-snapshot polling as resetting the cooldown" do
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      runner_state = create(:runner_state, user: project.effective_owner)

      runner_state.record_quota_status!(
        remaining: 100, limit: 200, reset_at: 1.hour.from_now, unit: "tokens", available: true, source: "provider"
      )

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when a runner's circuit breaker recovers" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      runner_state = create(:runner_state, :circuit_open, user: project.effective_owner)

      runner_state.record_success!(force_close: true)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat recovery on a runner outside the issue-analysis set as resetting the cooldown" do
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      # The RunnerState is for "cursor", which has no Runner record on the
      # owner in this test (the default UserSetting has empty
      # issue_analysis_runner / fallbacks, and only the default "claude"
      # Runner exists). A circuit recovery here cannot affect any provider
      # issue analysis can attempt, so it must not clear the cooldown.
      runner_state = create(:runner_state, :circuit_open,
        user: project.effective_owner, runner_name: "cursor")

      runner_state.record_success!(force_close: true)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat chat-capable runner recovery as resetting the cooldown when issue-analysis runner is pinned" do
      # Mirrors `chat_providers` in AnalyzeIssueActivity: when the owner has
      # explicitly configured an issue-analysis runner, the chat-capable
      # broadening is never consulted, so a circuit recovery on a runner
      # the analysis will not attempt must not clear the cooldown. Each
      # spurious reset re-mints a run that re-exhausts and re-records a
      # longer backoff, turning routine flapping on unrelated runners into
      # bounded churn.
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      project.effective_owner.settings.update!(issue_analysis_runner: "codex")
      create(:runner, user: project.effective_owner, runner_key: "codex")
      # `claude` is the default runner, chat-capable, but unreachable when
      # `issue_analysis_runner` is pinned to "codex" — a recovery here must
      # not bleed into the pinned codex path.
      claude_runner_state = create(:runner_state, :circuit_open,
        user: project.effective_owner, runner_name: "claude")

      claude_runner_state.record_success!(force_close: true)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when an integration credential backing a chat-capable runner rotates" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      credential = create(:integration_credential,
        service_key: "claude", category: "llm_provider", account: project.account)
      create(:runner, user: project.effective_owner, runner_key: "claude",
        auth_type: "api_key", integration_credential: credential)

      credential.update!(secret: "rotated-#{SecureRandom.hex(8)}")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "does not treat rotation of an unrelated integration credential as resetting the cooldown" do
      create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      # An integration credential not referenced by any chat-capable Runner
      # record — e.g. a non-LLM service credential like gitlab — must not
      # clear the cooldown, since its rotation cannot affect which
      # providers issue analysis can attempt.
      credential = create(:integration_credential, :gitlab, account: project.account)

      credential.update!(secret: "rotated-#{SecureRandom.hex(8)}")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "treats the cooldown as reset when the issue-analysis runner fallback list changes" do
      issue = create(:issue, project: project, paid_state: "failed",
        issue_analysis_next_attempt_at: 10.minutes.from_now,
        issue_analysis_backoff_set_at: 10.minutes.ago)
      settings = project.effective_owner.settings
      settings.update!(issue_analysis_runner: "codex")
      project.effective_owner.settings.reload

      settings.update!(issue_analysis_fallback_runners: [ "opencode" ])
      project.effective_owner.settings.reload

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "includes completed issues with no PR-producing run (infrastructure failure recovery)" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "includes completed issues when an auto-pick follow-up run completed without a PR" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "enhance_issue", auto_pick: true, pull_request_number: nil, pull_request_url: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes completed issues when the produced PR has not been synced yet" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "excludes an issue reset to a pre-completion paid_state after its create_pr run already recorded a PR number (#3432)" do # @spec EAGER-QUEUE-009
      # Mirrors the orphan-recovery race from #3432: a completed create_pr
      # run has already recorded a PR number, but the issue's paid_state
      # was reset back to "new" (e.g. by StaleRunDetectorJob recovering a
      # crashed workflow) before the local PR issue row synced. Without the
      # base-scope-level guard this issue would match the
      # paid_state: %w[new planning failed analyzed] branch directly,
      # bypassing the completed-issue PR-produced check entirely.
      issue = create(:issue, project: project, paid_state: "new")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "permanently excludes an issue reset to a pre-completion paid_state after its linked PR merged, even past the grace window" do
      # Reviewer follow-up on #3432/#3588: PR_SYNC_GRACE_PERIOD only bounds
      # the *bare pull_request_number* gap. Once the merged PR row is
      # authoritatively linked back to the source issue via parent_issue_id,
      # the issue must stay ineligible forever even if paid_state is later
      # reset back to "new".
      issue = create(:issue, project: project, paid_state: "new")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42",
        completed_at: described_class::PR_SYNC_GRACE_PERIOD.ago - 1.minute)
      create(:issue, :pull_request, :closed, project: project, github_number: 42, pr_review_phase: "merged",
        parent_issue: issue)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "recovers eligibility once the grace window elapses if the matched open PR row is still unlinked" do # @spec EAGER-QUEUE-009
      # A synced PR row without parent_issue_id is not authoritative enough
      # to block forever: if the run recorded the wrong PR number, an
      # unrelated open PR with that number must not strand the source issue.
      issue = create(:issue, project: project, paid_state: "new")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42",
        completed_at: described_class::PR_SYNC_GRACE_PERIOD.ago - 1.minute)
      create(:issue, project: project, github_number: 42, is_pull_request: true, github_state: "open",
        parent_issue_id: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "keeps an issue ineligible once a synced open PR row is linked back to it, even past the grace window" do
      issue = create(:issue, project: project, paid_state: "new")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42",
        completed_at: described_class::PR_SYNC_GRACE_PERIOD.ago - 1.minute)
      create(:issue, project: project, github_number: 42, is_pull_request: true, github_state: "open",
        parent_issue: issue)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "recovers eligibility once the PR-sync grace window elapses without a synced PR row" do # @spec EAGER-QUEUE-009
      # Missing/stale PR sync state must not block an issue forever: once
      # PR_SYNC_GRACE_PERIOD has passed with no local PR issue row proving
      # the PR is still open or closed-unmerged, the issue becomes eligible
      # again rather than being stranded.
      issue = create(:issue, project: project, paid_state: "new")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42",
        completed_at: described_class::PR_SYNC_GRACE_PERIOD.ago - 1.minute)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "recovers eligibility once the grace window elapses if the matched merged PR row is still unlinked" do # @spec EAGER-QUEUE-009
      issue = create(:issue, project: project, paid_state: "new")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42",
        completed_at: described_class::PR_SYNC_GRACE_PERIOD.ago - 1.minute)
      create(:issue, :pull_request, :closed, project: project, github_number: 42, pr_review_phase: "merged",
        parent_issue_id: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes completed issues when the produced PR is still open" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")
      create(:issue, project: project, github_number: 42, is_pull_request: true, github_state: "open")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "recovers completed issues when the produced PR was closed without merging" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")
      create(:issue, project: project, github_number: 42, is_pull_request: true, github_state: "closed")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "does not recover completed issues when the produced PR was merged" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 42, pull_request_url: "https://example.test/pr/42")
      create(:issue, :pull_request, :closed, project: project, github_number: 42, pr_review_phase: "merged")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "blocks recovery when one PR is closed but another is still open" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: 10, pull_request_url: "https://example.test/pr/10")
      create(:issue, project: project, github_number: 10, is_pull_request: true, github_state: "closed")
      create(:agent_run, :completed, project: project, issue: issue,
        goal: "create_pr", pull_request_number: 11, pull_request_url: "https://example.test/pr/11")
      create(:issue, project: project, github_number: 11, is_pull_request: true, github_state: "open")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "includes completed issues even when other PR-producing runs have NULL issue_id" do
      issue = create(:issue, project: project, paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)
      create(:agent_run, :completed, project: project, issue: nil, pull_request_number: 99,
        custom_prompt: "manual PR run")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    it "excludes completed issues whose completed run was not a recoverable auto-pick run" do
      manual_issue = create(:issue, project: project, paid_state: "completed", github_number: 50)
      analyze_issue = create(:issue, project: project, paid_state: "completed", github_number: 51)

      create(:agent_run, :completed, :manual, project: project, issue: manual_issue,
        goal: "create_pr", auto_pick: false, pull_request_number: nil, pull_request_url: nil)
      create(:agent_run, :completed, :automatic, project: project, issue: analyze_issue,
        goal: "analyze_issue", auto_pick: false, pull_request_number: nil, pull_request_url: nil)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "keeps a parent issue eligible when all of its sub-issues are closed" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, :closed, project: project, github_number: 2, parent_issue: parent)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(parent.id)
    end

    it "excludes a parent issue while it still has open non-PR sub-issues" do
      parent = create(:issue, project: project, github_number: 1)
      child = create(:issue, project: project, github_number: 2, parent_issue: parent)
      standalone = create(:issue, project: project, github_number: 3)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(child.id, standalone.id)
    end

    it "keeps a parent eligible when its only open sub-issue is recommend_close" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, :recommend_close, project: project, github_number: 2, parent_issue: parent)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to include(parent.id)
    end

    it "keeps a parent eligible when its only open sub-issue is completed" do
      parent = create(:issue, project: project, github_number: 1)
      create(:issue, :completed, project: project, github_number: 2, parent_issue: parent)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to include(parent.id)
    end

    # @spec AUTO-PICK-QUEUE-003
    it "does not resurrect a recommend_close issue with no dependencies during queue sweeps" do
      create(:issue, :recommend_close, project: project, github_number: 1)

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "uses project skip labels before user, tenant, and defaults" do
      project.update!(auto_pick_skip_labels: %w[blocked])
      project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])
      project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])
      create(:issue, project: project, labels: [ "blocked" ])
      eligible = create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "falls back to user skip labels when the project does not override them" do
      project.update!(auto_pick_skip_labels: nil)
      project.created_by.settings.update!(auto_pick_skip_labels: %w[user-skip])
      project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])
      create(:issue, project: project, labels: [ "user-skip" ])
      eligible = create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "falls back to tenant skip labels when neither project nor user override them" do
      project.update!(auto_pick_skip_labels: nil)
      project.created_by.settings.update!(auto_pick_skip_labels: nil)
      project.account.tenant_setting!.update!(auto_pick_skip_labels: %w[tenant-skip])
      create(:issue, project: project, labels: [ "tenant-skip" ])
      eligible = create(:issue, project: project, labels: [ "planning" ])

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(eligible.id)
    end

    it "falls back to the built-in skip labels when no overrides exist" do
      project.update!(auto_pick_skip_labels: nil)
      project.created_by.settings.update!(auto_pick_skip_labels: nil)
      project.account.tenant_setting!.update!(auto_pick_skip_labels: nil)
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.eligible_scope(project)).to be_empty
    end

    it "allows an explicit empty override to disable skip labels entirely" do
      project.update!(auto_pick_skip_labels: [])
      create(:issue, project: project, labels: [ "planning" ])

      expect(described_class.eligible_scope(project).pluck(:labels)).to include([ "planning" ])
    end

    it "matches allowlist entries case-insensitively against github_creator_login" do
      project.update!(allowed_github_usernames: [ "Viamin" ])
      issue = create(:issue, project: project, github_creator_login: "viamin")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to contain_exactly(issue.id)
    end

    # @spec AUTO-PICK-QUEUE-002 ISSUE-ANALYSIS-010
    it "skips the backoff reset-context query when no issue has an active backoff" do
      _eligible = create(:issue, project: project)

      expect(Issues::IssueAnalysisBackoffResetContext).not_to receive(:call)

      expect(described_class.eligible_scope(project).pluck(:id)).to contain_exactly(_eligible.id)
    end

    it "excludes issues whose creator is not in the allowlist regardless of case" do
      project.update!(allowed_github_usernames: [ "Viamin" ])
      create(:issue, project: project, github_creator_login: "otheruser")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to be_empty
    end

    it "includes issues with a '## Remaining work' body heading and no issue references" do
      issue = create(:issue, project: project,
        title: "RDR-011: complete observability stack",
        body: "## Remaining work\n- Add Prometheus config\n- Add Grafana dashboard")

      scope = described_class.eligible_scope(project)

      expect(scope.pluck(:id)).to include(issue.id)
    end
  end

  describe ".eligible_issue_ids" do
    it "returns the subset of displayed issues that are eligible" do
      eligible = create(:issue, project: project)
      planning = create(:issue, project: project, labels: [ "planning" ])

      result = described_class.eligible_issue_ids([ eligible, planning ])

      expect(result).to be_a(Set)
      expect(result).to include(eligible.id)
      expect(result).not_to include(planning.id)
    end

    it "returns an empty set when given an empty collection" do
      expect(described_class.eligible_issue_ids([])).to eq(Set.new)
    end
  end

  describe ".tracker_ids_blocked_by_open_references" do
    it "enqueues DependencyBackfillJob for referenced issues not in the database" do
      tracker = create(:issue, project: project, github_number: 1, title: "Tracker",
        body: "## Completion Criteria\n- [ ] #99\n- [ ] #100")
      _closed_ref = create(:issue, project: project, github_number: 100,
        github_state: "closed", is_pull_request: false)

      scope = Issue.where(id: tracker.id)

      allow(DependencyBackfillJob).to receive(:perform_later)

      described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(DependencyBackfillJob).to have_received(:perform_later).with(project.id, [ 99 ])
    end

    it "does not enqueue backfill when all referenced issues exist in the database" do
      tracker = create(:issue, project: project, github_number: 1, title: "Tracker",
        body: "## Completion Criteria\n- [ ] #100")
      _closed_ref = create(:issue, project: project, github_number: 100,
        github_state: "closed", is_pull_request: false)

      scope = Issue.where(id: tracker.id)

      allow(DependencyBackfillJob).to receive(:perform_later)

      described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(DependencyBackfillJob).not_to have_received(:perform_later)
    end

    it "blocks a title-matched tracker with no body references" do
      tracker = create(:issue, project: project, github_number: 1, title: "Phase 2 tracker",
        body: "Some notes without issue references")

      scope = Issue.where(id: tracker.id)

      blocked = described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(blocked).to include(tracker.id)
    end

    it "does not block a body-heading-matched tracker with no body references" do
      issue = create(:issue, project: project, github_number: 1,
        title: "Implement feature X",
        body: "## Completion criteria\n- Add tests\n- Add docs")

      scope = Issue.where(id: issue.id)

      blocked = described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(blocked).not_to include(issue.id)
    end

    it "blocks a strong body-heading-matched tracker with no body references" do
      issue = create(:issue, project: project, github_number: 1,
        title: "Implement feature X",
        body: "## Meta issue\nTracks all items")

      scope = Issue.where(id: issue.id)

      blocked = described_class.tracker_ids_blocked_by_open_references(scope, project)

      expect(blocked).to include(issue.id)
    end
  end

  describe "interface compliance" do
    it "responds to every method declared by the CandidateSource interface" do
      %i[eligible_issue_ids eligible_scope next_candidate].each do |method_name|
        expect(described_class).to respond_to(method_name)
      end
    end
  end
end
