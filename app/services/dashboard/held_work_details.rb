# frozen_string_literal: true

module Dashboard
  # @spec QUEUE-HANDOFF-004
  class HeldWorkDetails
    MAX_HELD_ISSUES = 20

    Blocker = Struct.new(:label, :url, keyword_init: true)
    Action = Struct.new(:label, :inbox_kind, :entry_id, keyword_init: true)
    HeldIssue = Struct.new(:issue, :blockers, :action, keyword_init: true)

    def self.call(...) = new(...).call

    def initialize(excluded:, project:)
      @excluded = excluded
      @project = project
    end

    def call
      blockers = dependency_blockers
      actions = decision_actions
      held_issues(blockers, actions)
    end

    private

    attr_reader :excluded, :project

    def held_issues(blockers, actions)
      ids = blockers.keys | actions.keys
      return [] if ids.empty?

      excluded.where(id: ids).order(:github_number).limit(MAX_HELD_ISSUES).map do |issue|
        HeldIssue.new(issue:, blockers: blockers.fetch(issue.id, []), action: actions[issue.id])
      end
    end

    def dependency_blockers
      [ local_dependency_blockers, deployment_dependency_blockers, external_dependency_blockers ]
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |blockers, result|
          blockers.each { |issue_id, issue_blockers| result[issue_id].concat(issue_blockers) }
        end
    end

    def local_dependency_blockers
      IssueDependency.joins(:issue, :depends_on_issue)
        .where(issue_id: excluded.select(:id), depends_on_issue: { github_state: "open" })
        .where.not(depends_on_issue: { paid_state: Issue::NON_BLOCKING_OPEN_DEPENDENCY_STATES })
        .excluding_parent_references
        .includes(:depends_on_issue)
        .each_with_object(blocker_map) { |dependency, blockers| append_local_blocker(dependency, blockers) }
    end

    def deployment_dependency_blockers
      IssueDependency.joins(:depends_on_issue)
        .where(issue_id: excluded.select(:id), requires_deployment: true)
        .where(depends_on_issue: { is_pull_request: true, deployed_at: nil })
        .where.not(depends_on_issue: { github_state: "open" })
        .includes(:depends_on_issue)
        .each_with_object(blocker_map) { |dependency, blockers| append_deployment_blocker(dependency, blockers) }
    end

    def external_dependency_blockers
      IssueDependency.still_blocking_external_for_account(project.account_id)
        .where(issue_id: excluded.select(:id))
        .each_with_object(blocker_map) { |dependency, blockers| append_external_blocker(dependency, blockers) }
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

    def decision_actions
      design_amendment_actions.merge(feature_decision_actions)
    end

    def design_amendment_actions
      DesignAmendmentPause.held.where(issue_id: excluded.select(:id)).joins(:design_amendment)
        .where(design_amendments: { project_id: project.id })
        .pluck(:issue_id)
        .to_h { |issue_id| [ issue_id, Action.new(label: "Review the design amendment hold in the issue") ] }
    end

    def feature_decision_actions
      FeatureIntentIssue.joins(:feature_intent)
        .where(issue_id: excluded.select(:id))
        .where(feature_hold_condition)
        .pluck(:issue_id, "feature_intents.id", "feature_intents.title")
        .to_h { |issue_id, id, title| [ issue_id, feature_action(id, title) ] }
    end

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
