# frozen_string_literal: true

module Issues
  # @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
  class StalledCloseoutProjection
    Result = Data.define(:pairs, :checkpoint, :used_projection)

    def self.call(project:, stalled_closeouts: StalledCloseouts)
      new(project:, stalled_closeouts:).call
    end

    def self.enqueue(project)
      return unless FeatureFlags.enabled?(:partial_closeout_lane_read_model, project:)

      RecomputePartialCloseoutProjectionJob.perform_later(project.id)
    end

    def self.read(projects, issue_id: nil)
      return [] if projects.empty?

      projected, fallback = projects.partition { |project| FeatureFlags.enabled?(:partial_closeout_lane_read_model, project:) }
      evaluated, unevaluated = projected.partition { |project| checkpointed?(project) }
      pairs = projected_pairs(evaluated, issue_id:)
      pairs.concat(Issues::StalledCloseouts.call(fallback, issue_id:)) if fallback.present?
      pairs.concat(Issues::StalledCloseouts.call(unevaluated, issue_id:)) if unevaluated.present?
      pairs
    end

    def self.projected_pairs(projects, issue_id:)
      return [] if projects.empty?

      scope = PartialCloseoutProjectionEntry.where(project_id: projects.map(&:id)).includes(:issue, :project)
      scope = scope.where(issue_id:) if issue_id
      scope.map do |entry|
        attributes = entry.status.symbolize_keys.merge(
          evidence: CloseoutEvidence.call(entry.issue),
          blockers: entry.blockers.map { |blocker| CloseoutStatus::Blocker.new(**blocker.symbolize_keys) },
          admissible: false,
          open_request: nil,
          resolved_current_generation: false,
          technical_evidence: []
        )
        StalledCloseouts::Pair.new(issue: entry.issue, status: CloseoutStatus::Result.new(**attributes))
      end
    end
    private_class_method :projected_pairs

    def self.checkpointed?(project)
      project.partial_closeout_projection&.computed_at.present?
    end
    private_class_method :checkpointed?

    def initialize(project:, stalled_closeouts:)
      @project = project
      @stalled_closeouts = stalled_closeouts
    end

    def call
      return unless FeatureFlags.enabled?(:partial_closeout_lane_read_model, project: project)

      failure = nil
      result = project.with_lock do
        begin
          PartialCloseoutProjection.transaction(requires_new: true) { replace_projection }
        rescue StandardError => error
          record_failure(error)
          failure = error
          nil
        end
      end
      raise failure if failure

      result
    end

    private

    attr_reader :project, :stalled_closeouts

    def replace_projection
      generation = SecureRandom.uuid
      pairs = stalled_closeouts.call([ project ])
      checkpoint = PartialCloseoutProjection.find_or_initialize_by(project: project)
      checkpoint.update!(computed_at: Time.current, generation:, input_watermark: Time.current,
        last_failure_at: nil, last_failure: {})
      checkpoint.entries.delete_all
      checkpoint.entries.insert_all(pairs.map { |pair| entry_attributes(pair, generation) }) if pairs.present?
      Result.new(pairs:, checkpoint:, used_projection: true)
    end

    def entry_attributes(pair, generation)
      status = pair.status
      {
        project_id: project.id,
        issue_id: pair.issue.id,
        evidence_digest: status.evidence.digest,
        status: {
          "outcome" => status.outcome,
          "unresolved_prerequisites" => status.unresolved_prerequisites
        },
        blockers: status.blockers.map(&:to_h),
        projection_generation: generation,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    def record_failure(error)
      checkpoint = PartialCloseoutProjection.find_or_initialize_by(project: project)
      checkpoint.update!(last_failure_at: Time.current, last_failure: { "class" => error.class.name, "message" => error.message.to_s.truncate(500) })
    end
  end
end
