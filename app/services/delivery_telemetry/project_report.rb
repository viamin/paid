# frozen_string_literal: true

module DeliveryTelemetry
  # Read-only delivery telemetry assembled from existing approval, audit,
  # conformance, issue, and agent-run records.
  # @spec DELIVERY-TELEMETRY-001, DELIVERY-TELEMETRY-002, DELIVERY-TELEMETRY-003, DELIVERY-TELEMETRY-004
  class ProjectReport
    def self.call(...)
      new(...).call
    end

    def initialize(project:, enforcement_activated_at: nil)
      @project = project
      @enforcement_activated_at = enforcement_activated_at
    end

    def call
      {
        completed_features: completed_features,
        approval_loop: approval_loop,
        escaped_drift: escaped_drift,
        delivery_time: delivery_time
      }
    end

    private

    attr_reader :project, :enforcement_activated_at

    def completed_features
      features.filter_map { |feature| feature_cycle(feature) }
    end

    def feature_cycle(feature)
      merged_pr = merged_implementation_pr(feature)
      return unless merged_pr

      create_feature_started_at = create_feature_started_at(feature)
      approved_at = feature.feature_intent_approval_revisions.minimum(:approved_at)
      released_at = release_time(feature)
      merged_at = terminal_time(merged_pr)

      {
        feature_intent_id: feature.id,
        create_feature_started_at: create_feature_started_at,
        approved_at: approved_at,
        released_at: released_at,
        implementation_merged_at: merged_at,
        cycle_time_seconds: duration_between(create_feature_started_at, merged_at),
        decisions_resolved_count: feature.feature_intent_decisions.count { |decision| decision.status == "resolved" },
        blockers_cleared_count: cleared_blocker_count(feature),
        stale_approval_count: stale_approval_count(feature)
      }
    end

    def approval_loop
      {
        time_to_clear_by_blocker: time_to_clear_by_blocker,
        vague_criteria_rate: vague_criteria_rate,
        stale_approval_churn: features.map { |feature| stale_approval_churn(feature) }
      }
    end

    def time_to_clear_by_blocker
      resolved_decisions.group_by { |decision| blocker_code_for(decision) }.map do |code, decisions|
        durations = decisions.filter_map { |decision| duration_between(decision.created_at, decision.resolved_at) }
        { code:, count: durations.size, total_seconds: durations.sum, average_seconds: average(durations) }
      end.sort_by { |row| row[:code] }
    end

    def vague_criteria_rate
      evaluated = features.select { |feature| feature.criteria_clarity_evaluated_at.present? }
      vague = evaluated.count { |feature| feature.criteria_clarity_state == "vague" }
      {
        reviewer_model: FeatureIntents::CriteriaClarityReview::DEFAULT_MODEL,
        prompt: "feature_intents.criteria_clarity_review",
        evaluated_count: evaluated.size,
        vague_count: vague,
        rate: rate(vague, evaluated.size)
      }
    end

    def stale_approval_churn(feature)
      {
        feature_intent_id: feature.id,
        approval_revision_count: feature.feature_intent_approval_revisions.size,
        stale_approval_count: stale_approval_count(feature),
        rate: rate(stale_approval_count(feature), feature.feature_intent_approval_revisions.size)
      }
    end

    def escaped_drift
      rows = within_scope_merged_verdicts.map { |verdict| escaped_drift_row(verdict) }
      { project: aggregate_escaped_drift(rows), by_reviewer_model: escaped_drift_by_model(rows) }
    end

    def escaped_drift_row(verdict)
      {
        reviewer_model: verdict.reviewer_model,
        escaped: DesignAmendment.where(feature_intent_id: feature_ids_for(verdict.issue_id),
          superseded_revision: verdict.approved_design_revision).where("created_at > ?", terminal_time(verdict.issue)).exists?
      }
    end

    def aggregate_escaped_drift(rows)
      numerator = rows.count { |row| row[:escaped] }
      { denominator: rows.size, numerator:, rate: rate(numerator, rows.size) }
    end

    def escaped_drift_by_model(rows)
      rows.group_by { |row| row[:reviewer_model] }.map do |model, model_rows|
        aggregate_escaped_drift(model_rows).merge(reviewer_model: model)
      end.sort_by { |row| row[:reviewer_model] }
    end

    def delivery_time
      return { baseline: delivery_summary([]), post_activation: delivery_summary([]) } unless enforcement_activated_at

      baseline, post_activation = terminal_pull_requests.partition { |pr| terminal_time(pr) < enforcement_activated_at }
      { baseline: delivery_summary(baseline), post_activation: delivery_summary(post_activation) }
    end

    def delivery_summary(pull_requests)
      durations = pull_requests.filter_map { |pr| duration_between(pr.github_created_at, terminal_time(pr)) }
      { count: durations.size, average_seconds: average(durations) }
    end

    def features
      @features ||= FeatureIntent.where(project:).includes(:feature_intent_approval_revisions, :feature_intent_design_prs,
        :feature_intent_decisions, :issues).to_a
    end

    def resolved_decisions
      features.flat_map(&:feature_intent_decisions).select { |decision| decision.status == "resolved" }
    end

    def merged_implementation_pr(feature)
      feature.issues.select { |issue| merged_pull_request?(issue) }.max_by { |issue| terminal_time(issue) }
    end

    def create_feature_started_at(feature)
      AgentRun.where(project:, goal: "create_feature", issue_id: feature.issues.map(&:id)).minimum(:started_at)
    end

    def release_time(feature)
      AccountActivityEvent.where(account: project.account, action: "feature_intent.released", subject: feature).minimum(:created_at) ||
        feature.approved_revision_recorded_at
    end

    def cleared_blocker_count(feature)
      feature.feature_intent_decisions.count { |decision| decision.status == "resolved" } +
        (feature.criteria_clarity_clear? && feature.criteria_clarity_evaluated_at ? 1 : 0)
    end

    def stale_approval_count(feature)
      current_heads = feature.feature_intent_design_prs.to_h { |design_pr| [ design_pr.pull_request_number.to_s, design_pr.head_sha ] }
      feature.feature_intent_approval_revisions.count { |revision| revision.pr_heads != current_heads }
    end

    def blocker_code_for(decision)
      decision.question? ? "unresolved_questions" : "unconfirmed_inferred_decisions"
    end

    def within_scope_merged_verdicts
      IntentConformanceVerdict.where(id: latest_verdict_ids, outcome: IntentConformanceVerdict::OUTCOME_WITHIN_SCOPE)
        .includes(:issue).select { |verdict| merged_pull_request?(verdict.issue) }
    end

    def latest_verdict_ids
      IntentConformanceVerdict.where(project:).select("DISTINCT ON (issue_id) id")
        .order(:issue_id, evaluated_at: :desc, id: :desc)
    end

    def feature_ids_for(issue_id)
      FeatureIntentIssue.where(issue_id:).select(:feature_intent_id)
    end

    def terminal_pull_requests
      @terminal_pull_requests ||= project.issues.where(is_pull_request: true, github_state: "closed", pr_review_phase: "merged").to_a
    end

    def merged_pull_request?(issue)
      issue.is_pull_request? && issue.github_state == "closed" && issue.pr_review_phase == "merged"
    end

    def terminal_time(issue)
      issue.closed_at || issue.github_updated_at
    end

    def duration_between(started_at, finished_at)
      return unless started_at && finished_at

      finished_at - started_at
    end

    def average(values)
      return nil if values.empty?

      values.sum.fdiv(values.size)
    end

    def rate(numerator, denominator)
      return nil if denominator.zero?

      numerator.fdiv(denominator)
    end
  end
end
