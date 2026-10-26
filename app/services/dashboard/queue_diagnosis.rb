# frozen_string_literal: true

module Dashboard
  # @spec QUEUE-DIAGNOSIS-001 @spec QUEUE-DIAGNOSIS-002 @spec QUEUE-DIAGNOSIS-003
  # Read-only explanation of why a visible scheduler queue is empty. Admission
  # remains owned by the candidate source and the periodic eligibility sweep.
  class QueueDiagnosis
    CACHE_TTL = 10.seconds
    Blocker = Struct.new(:issue, :blocking_issues, :kind, :next_action, keyword_init: true)
    Report = Struct.new(
      :state, :eligible_count, :queued_count, :schedulable_queued_count,
      :active_count, :blockers, :issues, :next_action, :checked_at,
      keyword_init: true
    )

    def self.call(...) = new(...).call

    def initialize(user:)
      @user = user
    end

    def call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build }
    rescue ActiveRecord::ActiveRecordError => error
      unknown(error)
    end

    private

    attr_reader :user

    def build
      breakdowns = EligibilityBreakdown.call(user: user)
      project_ids = visible_projects.ids
      counts = scheduler_counts(project_ids)
      return queued_report(counts) if counts[:queued].positive?
      return paused_report(counts) if paused_projects?

      eligible_count = breakdowns.sum(&:eligible)
      return active_report(counts, eligible_count) if counts[:active].positive? && eligible_count.zero?
      return unseeded_report(counts, eligible_count, breakdowns) if eligible_count.positive?

      blockers = blockers_for(project_ids)
      return held_report(counts, blockers) if blockers.any?

      empty_report(counts)
    end

    def visible_projects
      Project.where(account_id: user.account_id, created_by_id: visible_owner_ids, auto_pick_enabled: true, active: true)
    end

    def visible_owner_ids
      ids = [ user.id ]
      ids << nil if AgentRun.orphaned_project_owner?(user)
      ids
    end

    def scheduler_counts(project_ids)
      {
        queued: AgentRun.queued.where(project_id: project_ids).count,
        schedulable_queued: AgentRun.schedulable_queued_with_priority.where(project_id: project_ids).except(:select, :order).count,
        active: AgentRun.capacity_inflight.where(project_id: project_ids).count
      }
    end

    def paused_projects?
      user.account.scheduler_paused_at.present? || visible_projects.where.not(scheduler_paused_at: nil).exists? ||
        visible_projects.where.not(quality_paused_at: nil).exists?
    end

    def blockers_for(project_ids)
      open_issues = Issue.where(project_id: project_ids, github_state: "open", is_pull_request: false)
      dependency_blockers(open_issues) + decision_blockers(open_issues)
    end

    def dependency_blockers(open_issues)
      IssueDependency.includes(:issue, :depends_on_issue)
        .where(issue_id: open_issues.select(:id))
        .where.not(depends_on_issue_id: nil)
        .to_a
        .select { |dependency| blocking_dependency?(dependency) }
        .group_by(&:issue)
        .map do |issue, dependencies|
          Blocker.new(
            issue: issue,
            blocking_issues: dependencies.map(&:depends_on_issue),
            kind: :dependency,
            next_action: "Wait for the named dependency or resolve it in its project."
          )
        end
    end

    def blocking_dependency?(dependency)
      blocker = dependency.depends_on_issue
      blocker.github_state == "open" &&
        !Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES.include?(blocker.paid_state) &&
        dependency.issue.parent_issue_id != blocker.id
    end

    def decision_blockers(open_issues)
      open_issues.where(paid_state: %w[needs_input manual_review]).map do |issue|
        Blocker.new(
          issue: issue,
          blocking_issues: [],
          kind: :decision,
          next_action: "Open Inbox to provide the requested human decision."
        )
      end
    end

    def queued_report(counts)
      Report.new(
        state: counts[:schedulable_queued].positive? ? :queued : :backend_queued_not_rendered,
        eligible_count: 0, queued_count: counts[:queued], schedulable_queued_count: counts[:schedulable_queued],
        active_count: counts[:active], blockers: [], issues: [],
        next_action: counts[:schedulable_queued].positive? ? "Inspect the upcoming queue." : "Refresh; queued backend work is currently not schedulable for rendering.",
        checked_at: Time.current
      )
    end

    def paused_report(counts)
      report(:resource_or_policy_pause, counts, next_action: "Resume the project or scheduler only when authorized.")
    end

    def active_report(counts, eligible_count)
      report(:healthy_active_work, counts, eligible_count:, next_action: "Monitor active work; no eligible issue is waiting.")
    end

    def unseeded_report(counts, eligible_count, breakdowns)
      report(:runnable_unseeded, counts, eligible_count:, issues: eligible_issues(breakdowns),
        next_action: "The bounded eligibility sweep will seed normal admission.")
    end

    def eligible_issues(breakdowns)
      resolver = Runners::TierFeasibility.new
      breakdowns.flat_map do |breakdown|
        Automation::Strategies::AutoPick::DefaultCandidateSource
          .eligible_scope(breakdown.project, tier_feasibility: resolver).limit(20).to_a
      end
    end

    def held_report(counts, blockers)
      report(:dependency_or_decision_hold, counts, blockers:, next_action: "Inspect the named blocker or Inbox action.")
    end

    def empty_report(counts)
      report(:no_waiting_work, counts, next_action: "No visible work is waiting for admission.")
    end

    def report(state, counts, eligible_count: 0, blockers: [], issues: [], next_action:)
      Report.new(state:, eligible_count:, queued_count: counts[:queued], schedulable_queued_count: counts[:schedulable_queued],
        active_count: counts[:active], blockers:, issues:, next_action:, checked_at: Time.current)
    end

    def unknown(error)
      Rails.logger.warn(message: "dashboard.queue_diagnosis_unavailable", account_id: user.account_id, error_class: error.class.name)
      Report.new(state: :unknown, eligible_count: nil, queued_count: nil, schedulable_queued_count: nil,
        active_count: nil, blockers: [], issues: [], next_action: "Refresh diagnosis; coverage is currently unavailable.", checked_at: Time.current)
    end

    def cache_key
      "dashboard/queue_diagnosis/#{user.account_id}/#{user.id}/" \
        "#{CacheVersion.current(user.account, scope: CacheVersion::LISTS_SCOPE)}"
    end
  end
end
