# frozen_string_literal: true

module Issues
  class BulkEnqueueEligible
    PageResult = Struct.new(:runs, :last_issue_id, :candidate_count, :more?, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(project:, limit: nil, skip_project_gate: false, after_issue_id: nil, through_issue_id: nil, page_size: nil)
      @project = project
      @limit = limit
      @skip_project_gate = skip_project_gate
      @after_issue_id = after_issue_id
      @through_issue_id = through_issue_id
      @page_size = page_size
    end

    def call # @spec EAGER-QUEUE-003
      return [] unless skip_project_gate || Issues::AutoPickProjectGate.call(project)

      release_confidence_delivery_holds
      discover_agent_planning_holds
      reconcile_agent_planning_holds
      counts = { created: 0, existing: 0, skipped: 0 }
      runs = []

      issues.each do |issue|
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

      return runs unless page_size

      PageResult.new(
        runs:,
        last_issue_id: issues.last&.id,
        candidate_count: issues.size,
        more?: issues.size == page_size
      )
    end

    private

    attr_reader :project
    attr_reader :limit
    attr_reader :skip_project_gate
    attr_reader :after_issue_id
    attr_reader :through_issue_id
    attr_reader :page_size

    def issues
      return candidate_page if page_size

      each_eligible_issue.to_a
    end

    def each_eligible_issue
      return enum_for(:each_eligible_issue) unless block_given?
      return ordered_eligible_scope.each { |issue| yield issue } if limit.present?

      eligible_scope.find_each { |issue| yield issue }
    end

    # ID cursors remain stable while enqueueing changes the eligible scope.
    # The caller snapshots +through_issue_id+ before the first page, so new
    # records cannot keep one maintenance cycle open indefinitely.
    # @spec EAGER-QUEUE-017
    def candidate_page
      return [] unless through_issue_id

      scope = eligible_scope.where("issues.id > ? AND issues.id <= ?", after_issue_id.to_i, through_issue_id)
      scope.order(:id).limit(page_size).to_a
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
      AgentPlanningHold.where(project_id: project.id, status: %w[held needs_review reconciliation_failed]).find_each do |hold|
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
