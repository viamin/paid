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
    # @spec CONFIDENCE-DELIVERY-003 @spec CONFIDENCE-DELIVERY-006
    def release_confidence_delivery_holds
      FeatureIntentIssue.includes(:issue, :feature_intent)
        .joins(:feature_intent)
        .where(feature_intents: { project_id: project.id, delivery_policy: "confidence_driven" })
        .where.not(release_state: "released")
        .find_each { |link| FeatureIntents::ReleaseIssue.call(issue: link.issue) }
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
