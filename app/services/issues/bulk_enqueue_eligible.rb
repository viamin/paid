# frozen_string_literal: true

module Issues
  class BulkEnqueueEligible
    def self.call(...)
      new(...).call
    end

    def initialize(project:, limit: nil)
      @project = project
      @limit = limit
    end

    def call
      return [] unless project.auto_pick_enabled?

      counts = { created: 0, existing: 0, skipped: 0 }
      runs = []

      each_eligible_issue do |issue|
        run = EnqueueEligible.call(issue, project: project)

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

    def each_eligible_issue(&)
      return ordered_eligible_scope.limit(limit_query_cap).each(&) if limit.present?

      eligible_scope.find_each(&)
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

    def limit_query_cap
      limit * 10
    end
  end
end
