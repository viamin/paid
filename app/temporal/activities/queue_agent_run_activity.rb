# frozen_string_literal: true

module Activities
  class QueueAgentRunActivity < BaseActivity
    activity_name "QueueAgentRun"
    GOALS_REQUIRING_TRUSTED_ISSUE = %w[create_pr].freeze

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      custom_prompt = input[:custom_prompt]
      requested_agent_type = input[:agent_type]
      provider_id = input[:runner_id]
      source_pull_request_number = input[:source_pull_request_number]
      tdd_phase = input[:tdd_phase]
      goal = input[:goal]
      focus = input[:focus] || "general"
      trigger_type = input[:trigger_type]
      auto_pick = input.fetch(:auto_pick, false)
      count_toward_draft_review_round = input.fetch(:count_toward_draft_review_round, false)
      expected_draft_review_count = input[:expected_draft_review_count]

      project = Project.find(project_id)
      goal ||= project.account.tenant_setting&.default_goal || "create_pr"
      if trigger_type.nil? && goal == "create_pr" && source_pull_request_number.present?
        trigger_type = AgentRun.retry_trigger_type_for(
          project: project,
          source_pull_request_number: source_pull_request_number,
          goal: goal
        )
      end
      trigger_type ||= "automatic"
      issue = issue_id ? Issue.find(issue_id) : nil

      # PR follow-up runs (source_pull_request_number present) intentionally do
      # not reuse the issue-trust gate below. They are authorized upstream by
      # ScanPaidPrsActivity#authorized_for_automation_scan? (trusted authors,
      # dependency-update bots, or trusted-user-added labels) or by
      # LabelPolicy#authorized_for_trigger?. BuildForPr still filters comment
      # bodies independently, so this bypass only affects run creation.
      pr_followup_run = source_pull_request_number.present?
      if issue_requires_trust?(goal) && issue&.untrusted? && !pr_followup_run
        logger.info(
          message: "queue_agent_run.untrusted_issue_skipped",
          project_id: project.id,
          issue_id: issue.id,
          github_creator_login: issue.github_creator_login,
          goal: goal
        )
        return { queued: false, skipped: true, reason: "untrusted_issue" }
      end

      respect_requested = input.key?(:agent_type) || input.key?(:runner_id)
      provider_id, agent_type = resolve_runner_selection(
        project: project,
        requested_agent_type: requested_agent_type,
        requested_runner_id: provider_id,
        goal: goal,
        agent_type_provided: input.key?(:agent_type),
        runner_id_provided: input.key?(:runner_id)
      )

      # Use a transaction with row-level locking to prevent duplicate
      # queued/active runs for the same issue or PR under concurrency.
      # Falls back to DB unique indexes (RecordNotUnique) as a safety net
      # for races between concurrent activity executions.
      agent_run, duplicate, enhancement_limit_reached = AgentRun.transaction do
        issue.lock! if automatic_enhancement?(goal, trigger_type, issue)
        existing = find_existing_run(project, issue, source_pull_request_number)
        if existing
          if existing.goal == goal
            merge_draft_review_round_tracking!(existing,
              count_toward_draft_review_round: count_toward_draft_review_round,
              expected_draft_review_count: expected_draft_review_count)
          end
          [ existing, true, false ]
        elsif enhancement_round_limit_reached?(project, issue, goal, trigger_type)
          [ nil, false, true ]
        else
          consume_enhancement_round!(issue) if automatic_enhancement?(goal, trigger_type, issue)
          run = AgentRun.create!(
            project: project,
            issue: issue,
            initiating_user_id: input[:initiating_user_id],
            provider_id: provider_id,
            agent_type: agent_type,
            custom_prompt: custom_prompt,
            source_pull_request_number: source_pull_request_number,
            goal: goal,
            focus: focus,
            tdd_phase: tdd_phase,
            trigger_type: trigger_type,
            auto_pick: auto_pick,
            count_toward_draft_review_round: count_toward_draft_review_round,
            expected_draft_review_count: expected_draft_review_count,
            status: "queued"
          )
          snapshot_page_load_evidence!(run, input[:focus_evidence])
          [ run, false, false ]
        end
      rescue ActiveRecord::RecordNotUnique
        existing = find_existing_run(project, issue, source_pull_request_number)
        raise unless existing

        # Runs outside the rolled-back transaction without a row lock. If two
        # concurrent RecordNotUnique rescues race here, the idempotency guard in
        # merge_draft_review_round_tracking! prevents double-writes. Both callers
        # originate from the same poll cycle so they pass identical values; the
        # last writer wins harmlessly.
        if existing.goal == goal
          merge_draft_review_round_tracking!(existing,
            count_toward_draft_review_round: count_toward_draft_review_round,
            expected_draft_review_count: expected_draft_review_count)
        end

        [ existing, true, false ]
      end

      if enhancement_limit_reached
        stop_for_enhancement_limit(project, issue)
        return { queued: false, skipped: true, reason: "enhancement_round_limit" }
      end

      if duplicate
        logger.info(
          message: "concurrency.duplicate_run_skipped",
          agent_run_id: agent_run.id,
          project_id: project_id,
          issue_id: issue_id,
          requested_goal: goal,
          existing_goal: agent_run.goal,
          cross_goal: agent_run.goal != goal
        )
        return { agent_run_id: agent_run.id, queued: false, duplicate: true,
                 cross_goal: agent_run.goal != goal }
      end

      AgentRuns::RunnerSelectionLogger.call(
        project: project,
        issue: issue,
        agent_run: agent_run,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: input[:runner_id],
        respect_requested: respect_requested,
        resolved_runner_id: provider_id,
        resolved_agent_type: agent_type
      )

      logger.info(
        message: "concurrency.agent_run_queued",
        agent_run_id: agent_run.id,
        project_id: project_id,
        issue_id: issue_id
      )

      ProcessRunQueueJob.perform_later

      { agent_run_id: agent_run.id, queued: true }
    end

    private

    def automatic_enhancement?(goal, trigger_type, issue)
      issue.present? && goal == "enhance_issue" && trigger_type == "automatic"
    end

    def enhancement_round_limit_reached?(project, issue, goal, trigger_type)
      automatic_enhancement?(goal, trigger_type, issue) &&
        issue.enhance_issue_rounds >= project.max_enhance_issue_reevaluation_rounds
    end

    # @spec ISSUE-ENHANCEMENT-011
    def consume_enhancement_round!(issue)
      issue.update!(enhance_issue_rounds: issue.enhance_issue_rounds + 1)
    end

    def stop_for_enhancement_limit(project, issue)
      IssueEnhancements::StopForManualReview.call(
        project: project,
        issue: issue,
        reason: "Paid reached the configured enhancement-round limit."
      )
    end

    def resolve_runner_selection(project:, requested_agent_type:, requested_runner_id:, goal:, agent_type_provided:, runner_id_provided:)
      AgentRuns::RunnerResolver.call(
        project: project,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        respect_requested: runner_id_provided || agent_type_provided,
        logger: logger
      )
    end

    # A performance follow-up run carries the regression it was queued for. The
    # snapshot is taken once, at creation, so a later capture that updates the
    # finding cannot change what this run was asked to fix. The evidence the
    # scanner threads through carries the finding's id, so the attempt
    # accounting lands on the exact finding that selected the run even when a
    # later capture resolved it and reopened the same route as a new row.
    # @spec PAGE-LOAD-FOLLOWUP-004
    def snapshot_page_load_evidence!(run, provided_evidence)
      return unless run.focus == "performance_regression"

      finding = find_page_load_finding(run, provided_evidence)
      evidence = provided_evidence.presence || finding&.evidence
      return if evidence.blank?

      # @spec PAGE-LOAD-FOLLOWUP-006
      finding&.record_followup_attempt!

      metadata = run.external_metadata.is_a?(Hash) ? run.external_metadata.deep_dup : {}
      metadata["page_load_regression"] = evidence.deep_stringify_keys
      run.update_columns(external_metadata: metadata)
    end

    def find_page_load_finding(run, evidence)
      scope = PageLoadRegressionFinding
        .where(project_id: run.project_id, pull_request_number: run.source_pull_request_number)

      # The id is immutable and deliberately ignores status: a finding that
      # resolved between trigger and queue still owns the attempt this run
      # spends on it. Re-selecting by route would debit a reopened finding for
      # a run it never asked for.
      finding_id = finding_id_from_evidence(evidence)
      return scope.find_by(id: finding_id) if finding_id

      scope = scope.open_findings.actionable
      route_name = route_name_from_evidence(evidence)
      scope = scope.where(route_name: route_name) if route_name

      scope.order(updated_at: :desc).first
    end

    # Activity input arrives through BaseActivity::InputNormalizer, which
    # deep_symbolize_keys the payload, so the evidence can come in with either
    # string keys (in-process callers, the prompt renderer) or symbol keys
    # (Temporal-serialized input). Accept either shape.
    def finding_id_from_evidence(evidence)
      return nil unless evidence.is_a?(Hash)

      evidence[:finding_id].presence || evidence["finding_id"].presence
    end

    def route_name_from_evidence(evidence)
      return nil unless evidence.is_a?(Hash)

      evidence[:route_name].presence || evidence["route_name"].presence
    end

    def issue_requires_trust?(goal)
      GOALS_REQUIRING_TRUSTED_ISSUE.include?(goal)
    end

    # Returns nil for custom-prompt-only runs (no issue or PR) intentionally:
    # custom prompts are unique by definition and cannot be meaningfully deduplicated.
    #
    # Deduplication is goal-agnostic: any unfinished — or rate_limited (parked,
    # awaiting recovery) — run for the same issue or source PR blocks queueing
    # another. A rate_limited run still holds the work slot and will re-queue,
    # so treating it as in-flight prevents re-triggering pumps (e.g. the PR
    # CI-fix scanner) from minting a duplicate every cycle. Two runs against the
    # same PR share a branch and worktree (e.g. a review and a create_pr both
    # cloned to /workspace), so allowing them to run concurrently caused
    # WorktreeConflict failures whenever the poll cycle fired both at once. The
    # poller will re-evaluate next cycle once the in-flight run finishes.
    def find_existing_run(project, issue, source_pull_request_number)
      scope = project.agent_runs.where(status: AgentRun::DEDUP_BLOCKING_STATUSES).lock("FOR UPDATE")
      if issue
        scope.where(issue: issue).first
      elsif source_pull_request_number
        scope.where(source_pull_request_number: source_pull_request_number).first
      end
    end

    def merge_draft_review_round_tracking!(agent_run, count_toward_draft_review_round:, expected_draft_review_count:)
      return unless count_toward_draft_review_round
      return if agent_run.count_toward_draft_review_round? &&
        agent_run.expected_draft_review_count.present?

      if agent_run.trigger_type != "automatic"
        logger.warn(
          message: "concurrency.draft_tracking_skipped_manual_run",
          agent_run_id: agent_run.id
        )
        return
      end

      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: expected_draft_review_count
      )
    end
  end
end
