# frozen_string_literal: true

module Issues
  # Queue-seeding orchestration wrapper around
  # {Automation::Strategies::AutoPick}.
  #
  # Responsibilities kept here (orchestration):
  # - Collecting project-level guard signals (count of open PRs that still
  #   need attention, configured WIP limit).
  # - Running the pure-policy strategy and executing the resulting
  #   decision — resolving a runnable provider and creating the queued
  #   {AgentRun}.
  # - Race-safe handling of the +idx_agent_runs_unique_active_issue+
  #   unique index (returning the run created by a competing picker) and
  #   structured logging of the selection/dedup outcome.
  #
  # Selection and ordering rules themselves live in
  # {Automation::Strategies::AutoPick} and its +CandidateSource+, so any
  # future work-item provider can plug in without changing this service.
  #
  # Returns the created (or existing) {AgentRun}, or +nil+ when no
  # eligible issue is found, guards defer the pick, or no runnable
  # provider can be resolved.
  class AutoPick
    NoRunnableProviderError = Class.new(StandardError)

    PAID_READY_LABEL = "paid-ready"
    BLOCKING_PARENT_REVIEW_SOURCE = "blocking_parent_issue_review"

    # Returns the Set of issue IDs from +displayed_issues+ that are
    # currently eligible for auto-picking (per-issue criteria only;
    # ignores transient project-level guards like active runs or PRs
    # needing attention). Scoping to the displayed issues helps limit
    # query cost and focuses results on the currently displayed subset.
    def self.eligible_issue_ids(displayed_issues)
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_issue_ids(displayed_issues)
    end

    def initialize(project)
      @project = project
    end

    def call
      sync_blocking_parent_review_notifications if should_sync_blocking_parent_reviews?

      result = strategy.evaluate(build_context)
      decision = result.decisions.first
      return nil if decision.nil? || decision.type == "noop"

      issue_id = decision.payload.fetch(:issue_id)
      issue = Issue.find_by(id: issue_id)
      # Race: another process may have deleted the issue between the
      # strategy's candidate lookup and this find. Treat it like the
      # duplicate_skipped path rather than letting RecordNotFound escape
      # the rescues below and abort the queue-seed tick.
      return nil unless issue

      goal = decision.type == "queue_analyze_issue_run" ? "analyze_issue" : "create_pr"
      agent_run = create_agent_run(issue, goal: goal)

      Rails.logger.info(
        message: "auto_pick.issue_selected",
        project_id: @project.id,
        issue_id: issue.id,
        issue_number: issue.github_number,
        agent_run_id: agent_run.id
      )

      agent_run
    rescue ActiveRecord::RecordNotUnique => e
      message = e.cause&.message || e.message
      raise unless message&.include?("idx_agent_runs_unique_active_issue")

      # Another process already created a run for this issue.
      # Re-query for the existing active/queued run so callers can use
      # it.
      existing_run = AgentRun.find_by(
        project: @project,
        issue: issue,
        status: AgentRun::AUTO_PICK_BLOCKING_STATUSES
      )

      if existing_run
        Rails.logger.info(
          message: "auto_pick.duplicate_existing_run",
          project_id: @project.id,
          issue_id: issue&.id,
          agent_run_id: existing_run.id
        )
        existing_run
      else
        Rails.logger.info(
          message: "auto_pick.duplicate_skipped",
          project_id: @project.id,
          issue_id: issue&.id
        )
        nil
      end
    rescue NoRunnableProviderError => e
      Rails.logger.warn(
        message: "auto_pick.no_runnable_provider",
        project_id: @project.id,
        error: e.message
      )
      nil
    end

    private

    def strategy
      @strategy ||= Automation::Strategies::Select.call(
        strategy_type: :auto_pick,
        project: @project
      )
    end

    def should_sync_blocking_parent_reviews?
      @project.auto_pick_enabled? && !@project.quality_paused?
    end

    def sync_blocking_parent_review_notifications
      review_issues = Automation::Strategies::AutoPick::DefaultCandidateSource
        .review_required_parent_scope(@project)
        .includes(:sub_issues)
        .to_a

      review_issues.each { |issue| publish_blocking_parent_review_notification(issue) }

      unresolved_blocking_parent_notifications(review_issues.map(&:id)).find_each do |notification|
        Notifications::Resolve.call(
          account: notification.account,
          user: notification.user,
          source: BLOCKING_PARENT_REVIEW_SOURCE,
          subject: notification.subject
        )
      end
    end

    def publish_blocking_parent_review_notification(issue)
      open_child_numbers = issue.sub_issues
        .select { |sub_issue| !sub_issue.is_pull_request? && sub_issue.github_state == "open" }
        .map(&:github_number)
        .sort

      blocking_issue_count = IssueDependency.joins(:issue)
        .where(depends_on_issue: issue)
        .where(issues: { project_id: @project.id, github_state: "open", is_pull_request: false })
        .distinct
        .count(:issue_id)

      Notifications::Publish.call(
        account: @project.account,
        user: @project.effective_owner,
        source: BLOCKING_PARENT_REVIEW_SOURCE,
        subject: issue,
        severity: :warning,
        title: "Parent issue ##{issue.github_number} is blocking auto-pick",
        description: "Open child issues: #{open_child_numbers.map { |n| "##{n}" }.join(", ")}. " \
          "Review close-out work so #{blocking_issue_count} blocked issue#{'s' unless blocking_issue_count == 1} can move forward.",
        nav_section: "dashboard",
        action_url: "/projects/#{@project.id}",
        metadata: {
          issue_number: issue.github_number,
          open_child_issue_numbers: open_child_numbers,
          blocking_issue_count: blocking_issue_count
        }
      )
    end

    def unresolved_blocking_parent_notifications(active_issue_ids)
      scope = Notification.where(
        account: @project.account,
        user: @project.effective_owner,
        source: BLOCKING_PARENT_REVIEW_SOURCE,
        subject_type: "Issue",
        subject_id: @project.issues.select(:id),
        resolved_at: nil
      )

      return scope if active_issue_ids.empty?

      scope.where.not(subject_id: active_issue_ids)
    end

    def build_context
      context = Automation::Context.build(record: nil, project: @project, metadata: {})
      # Avoid expensive PR-attention query when early guards will noop.
      return context unless @project.auto_pick_enabled? && !@project.quality_paused?

      context.with_metadata(
        Automation::Strategies::AutoPick::PR_ATTENTION_COUNT_KEY => prs_needing_attention_count,
        Automation::Strategies::AutoPick::PR_ATTENTION_LIMIT_KEY => max_auto_pick_open_prs
      )
    end

    # Returns the count of open PRs that still need Paid's attention.
    # A PR "needs attention" if it is failed, or in_progress but not
    # yet handed off (missing the automation/ready labels, or still in
    # draft/restarted phase).
    #
    # Escalated PRs are excluded because they have already been surfaced
    # to the owner for attention — keeping them in the count would let
    # operationally stalled PRs (e.g. provider exhaustion, repeated
    # timeouts) block auto-pick indefinitely even after escalation.
    #
    # Uses a single COUNT query. The handed_off subquery only matches
    # in_progress rows, so failed PRs are never excluded by it.
    def prs_needing_attention_count
      base = Issue.where(
        project: @project,
        is_pull_request: true,
        github_state: "open",
        paid_state: %w[in_progress failed]
      )

      handed_off = base
        .where(paid_state: "in_progress")
        .where("labels @> ?::jsonb", [ @project.automation_label_name, PAID_READY_LABEL ].to_json)
        .where.not(pr_review_phase: %w[draft restarted])

      escalated = base.where(pr_review_phase: "escalated")

      base.where.not(id: handed_off).where.not(id: escalated).count
    end

    def max_auto_pick_open_prs
      owner = @project.effective_owner
      return 1 unless owner

      owner.settings.max_auto_pick_open_prs
    end

    def create_agent_run(issue, goal: "create_pr")
      provider = resolve_provider(goal)
      raise NoRunnableProviderError, "No runnable provider could be resolved for this project." unless provider

      AgentRun.create!(
        project: @project,
        issue: issue,
        provider: provider,
        agent_type: Provider.agent_type_for(provider.provider_key),
        status: "queued",
        trigger_type: "automatic",
        auto_pick: true,
        goal: goal
      )
    end

    def resolve_provider(goal)
      provider_id, = AgentRuns::ProviderResolver.call(project: @project, goal: goal)
      Provider.find_by(id: provider_id) if provider_id
    end
  end
end
