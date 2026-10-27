# frozen_string_literal: true

module Dashboard
  # @spec QUEUE-HANDOFF-004
  class HeldWorkDetails
    MAX_HELD_ISSUES = 20

    Blocker = Struct.new(:label, :url, keyword_init: true)
    Action = Struct.new(:label, :inbox_kind, :entry_id, keyword_init: true)
    HeldIssue = Struct.new(:issue, :blockers, :actions, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(excluded:, projects:)
      @excluded = excluded
      @projects = projects
    end

    def call
      issue_ids = held_issue_ids
      blockers = dependency_blockers(issue_ids)
      actions = decision_actions(issue_ids)
      held_issues(issue_ids, blockers, actions).group_by { |held_issue| held_issue.issue.project_id }
    end

    private

    attr_reader :excluded, :projects

    def held_issue_ids
      ranked_held_issues.where("held_issue_rank <= ?", MAX_HELD_ISSUES).pluck(Arel.sql("held_issues.id"))
    end

    def ranked_held_issues
      Issue.unscoped.from("(#{held_issue_candidates.to_sql}) AS held_issues")
    end

    def held_issue_candidates
      excluded.where(held_issue_predicate)
        .select("issues.id, ROW_NUMBER() OVER (PARTITION BY issues.project_id ORDER BY issues.github_number) AS held_issue_rank")
    end

    def held_issue_predicate
      @held_issue_predicate ||= held_issue_candidate_scopes
        .map { |scope| "issues.id IN (#{scope.select(:issue_id).to_sql})" }
        .join(" OR ")
    end

    def held_issue_candidate_scopes
      [ local_dependency_blocker_scope, deployment_dependency_blocker_scope, external_dependency_blocker_scope,
       design_amendment_action_scope, feature_decision_action_scope ]
    end

    def held_issues(issue_ids, blockers, actions)
      return [] if issue_ids.empty?

      excluded.where(id: issue_ids).order(:project_id, :github_number).map do |issue|
        HeldIssue.new(issue:, blockers: blockers.fetch(issue.id, []), actions: actions.fetch(issue.id, []))
      end
    end

    def dependency_blockers(issue_ids)
      [ local_dependency_blockers(issue_ids), deployment_dependency_blockers(issue_ids), external_dependency_blockers(issue_ids) ]
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |blockers, result|
          blockers.each { |issue_id, issue_blockers| result[issue_id].concat(issue_blockers) }
        end
    end

    def local_dependency_blockers(issue_ids = excluded.select(:id))
      local_dependency_blocker_scope(issue_ids).includes(:depends_on_issue)
        .each_with_object(blocker_map) { |dependency, blockers| append_local_blocker(dependency, blockers) }
    end

    def local_dependency_blocker_scope(issue_ids = excluded.select(:id))
      IssueDependency.joins(:issue, :depends_on_issue)
        .where(issue_id: issue_ids, depends_on_issue: { github_state: "open" })
        .where.not(depends_on_issue: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
        .excluding_parent_references
    end

    def deployment_dependency_blockers(issue_ids = excluded.select(:id))
      deployment_dependency_blocker_scope(issue_ids).includes(:depends_on_issue)
        .each_with_object(blocker_map) { |dependency, blockers| append_deployment_blocker(dependency, blockers) }
    end

    def deployment_dependency_blocker_scope(issue_ids = excluded.select(:id))
      IssueDependency.joins(:depends_on_issue)
        .where(issue_id: issue_ids, requires_deployment: true)
        .where(depends_on_issue: { is_pull_request: true, deployed_at: nil })
        .where.not(depends_on_issue: { github_state: "open" })
    end

    def external_dependency_blockers(issue_ids = excluded.select(:id))
      external_dependency_blocker_scope(issue_ids)
        .each_with_object(blocker_map) { |dependency, blockers| append_external_blocker(dependency, blockers) }
    end

    def external_dependency_blocker_scope(issue_ids = excluded.select(:id))
      IssueDependency.still_blocking_external_for_account(projects.first.account_id).where(issue_id: issue_ids)
    end

    def blocker_map = Hash.new { |hash, key| hash[key] = [] }

    def append_local_blocker(dependency, blockers)
      target = dependency.depends_on_issue
      blockers[dependency.issue_id] << Blocker.new(label: "##{target.github_number} #{target.title}", url: target.github_url)
    end

    def append_deployment_blocker(dependency, blockers)
      target = dependency.depends_on_issue
      blockers[dependency.issue_id] << Blocker.new(label: "##{target.github_number} #{target.title} (awaiting deployment)", url: target.github_url)
    end

    def append_external_blocker(dependency, blockers)
      ref = dependency.external_ref
      blockers[dependency.issue_id] << Blocker.new(label: "#{ref} (external dependency)", url: "https://github.com/#{ref.sub("#", "/issues/")}")
    end

    def decision_actions(issue_ids)
      [ design_amendment_actions(issue_ids), feature_decision_actions(issue_ids) ]
        .each_with_object(action_map) do |actions, result|
          actions.each { |issue_id, issue_actions| result[issue_id].concat(issue_actions) }
        end
    end

    def design_amendment_actions(issue_ids = excluded.select(:id))
      design_amendment_action_scope(issue_ids)
        .pluck(:issue_id)
        .each_with_object(action_map) do |issue_id, actions|
          actions[issue_id] << Action.new(label: "Review the design amendment hold in the issue")
        end
    end

    def design_amendment_action_scope(issue_ids = excluded.select(:id))
      DesignAmendmentPause.held.where(issue_id: issue_ids).joins(:design_amendment)
        .where(design_amendments: { project_id: projects.map(&:id) })
    end

    def feature_decision_actions(issue_ids = excluded.select(:id))
      feature_decision_action_scope(issue_ids)
        .pluck(:issue_id, "feature_intents.id", "feature_intents.title")
        .each_with_object(action_map) do |(issue_id, id, title), actions|
          actions[issue_id] << feature_action(id, title)
        end
    end

    def feature_decision_action_scope(issue_ids = excluded.select(:id))
      FeatureIntentIssue.joins(:feature_intent)
        .where(issue_id: issue_ids)
        .where(feature_hold_condition)
    end

    def action_map = Hash.new { |hash, key| hash[key] = [] }

    def feature_hold_condition
      "(feature_intents.delivery_policy = 'approval_gated' AND " \
        "(feature_intents.status != 'released' OR feature_intents.approved_design_revision IS NULL)) OR " \
        "(feature_intents.delivery_policy = 'confidence_driven' AND feature_intent_issues.release_state != 'released')"
    end

    def feature_action(id, title)
      Action.new(
        label: "Review feature decision: #{title}",
        inbox_kind: Inbox::Queue::FEATURE_DECISION_KIND,
        entry_id: "#{Inbox::Queue::FEATURE_DECISION_KIND}:#{id}"
      )
    end
  end
end
