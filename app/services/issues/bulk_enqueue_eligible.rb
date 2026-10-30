# frozen_string_literal: true

module Issues
  class BulkEnqueueEligible
    def self.call(...)
      new(...).call
    end

    def initialize(project:, limit: nil, skip_project_gate: false)
      @project = project
      @limit = limit
      @skip_project_gate = skip_project_gate
    end

    def call # @spec EAGER-QUEUE-003
      return [] unless skip_project_gate || Issues::AutoPickProjectGate.call(project)

      release_confidence_delivery_holds
      discover_agent_planning_holds
      reconcile_agent_planning_holds
      counts = { created: 0, existing: 0, skipped: 0 }
      runs = []

      each_eligible_issue do |issue|
        run = EnqueueEligible.call(issue, project: project, skip_project_gate: true)

        if run.nil?
          counts[:skipped] += 1
          next
        end

        runs << run
        key = run.previously_new_record? ? :created : :existing
        counts[key] += 1
        break if limit_reached?(counts)
      end

      Rails.logger.info(
        message: "bulk_enqueue_eligible.completed",
        project_id: project.id,
        created_count: counts[:created],
        existing_count: counts[:existing],
        skipped_count: counts[:skipped]
      )

      runs
    end

    private

    attr_reader :project
    attr_reader :limit
    attr_reader :skip_project_gate

    def each_eligible_issue(&)
      return ordered_eligible_scope.each(&) if limit.present?

      eligible_scope.find_each(&)
    end

    # Held confidence-delivery issues are intentionally absent from the normal
    # candidate scope while their GitHub planning projection is unresolved.
    # Reconcile them before reading that scope, so the periodic eager-queue
    # sweep can release newly-ready work without treating a label as evidence.
    # An issue may serve several designs, so reconciliation runs once per
    # issue — ReleaseIssue reconciles every unreleased confidence link the
    # issue serves as one set. Fully released issues are swept only while the
    # workflow-owned planning label is still projected on them, so an
    # externally re-added hold cannot silently hold ready work forever.
    # @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-006
    def release_confidence_delivery_holds
      issue_ids = unreleased_confidence_issue_ids | stale_planning_label_issue_ids
      Issue.where(id: issue_ids).find_each { |issue| FeatureIntents::ReleaseIssue.call(issue: issue) }
    end

    # Labels that predate the proxy receipt have no trustworthy provenance.
    # Record them as operator review work before selecting durable contracts,
    # rather than allowing label-based auto-pick exclusion to hide them forever.
    # @spec CONFIDENCE-DELIVERY-018
    def discover_agent_planning_holds
      AgentPlanningHolds::Discover.call(project:)
    end

    # Direct agent GitHub writes are not FeatureIntent publications. Sweep the
    # bounded set of durable contracts separately so they cannot be skipped
    # forever simply because they have no confidence-delivery link.
    # @spec CONFIDENCE-DELIVERY-018
    def reconcile_agent_planning_holds
      AgentPlanningHold.where(project_id: project.id, status: %w[held reconciliation_failed]).find_each do |hold|
        AgentPlanningHolds::Reconcile.call(hold:)
      end
    end

    def unreleased_confidence_issue_ids
      FeatureIntentIssue.joins(:feature_intent)
        .where(feature_intents: { project_id: project.id, delivery_policy: "confidence_driven" })
        .where.not(release_state: "released")
        .distinct.pluck(:issue_id)
    end

    # The planning label is a default auto-pick skip label, so a fully
    # released issue would never re-enter any selection path while an
    # externally re-added hold stays on it (CONFIDENCE-DELIVERY-006).
    def stale_planning_label_issue_ids
      FeatureIntentIssue.joins(:feature_intent, :issue)
        .where(feature_intents: { project_id: project.id, delivery_policy: "confidence_driven" })
        .where(release_state: "released")
        .where("issues.labels @> ?::jsonb", [ FeatureIntents::ReleaseIssue::PLANNING_LABEL ].to_json)
        .distinct.pluck(:issue_id)
    end

    def eligible_scope
      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_scope(project)
    end

    def ordered_eligible_scope
      Automation::Strategies::AutoPick::DefaultCandidateSource.ordered_scope(project)
    end

    def limit_reached?(counts)
      limit.present? && counts[:created] >= limit
    end
  end
end
