# frozen_string_literal: true

module Issues
  # @spec PARTIAL-CLOSEOUT-042 @spec PARTIAL-CLOSEOUT-043
  class StalledCloseoutProjection
    ADVISORY_LOCK_SQL = "SELECT 1 FROM pg_advisory_xact_lock(hashtextextended($1, 0))".freeze
    ADVISORY_LOCK_NAMESPACE = "partial_closeout_projection".freeze

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
      evaluated_ids = checkpointed_project_ids(projected)
      evaluated, unevaluated = projected.partition { |project| evaluated_ids.include?(project.id) }
      pairs = projected_pairs(evaluated, issue_id:)
      pairs.concat(Issues::StalledCloseouts.call(fallback, issue_id:)) if fallback.present?
      pairs.concat(Issues::StalledCloseouts.call(unevaluated, issue_id:)) if unevaluated.present?
      pairs
    end

    def self.projected_pairs(projects, issue_id:)
      return [] if projects.empty?

      scope = PartialCloseoutProjectionEntry.where(project_id: projects.map(&:id)).includes(issue: :project)
      scope = scope.where(issue_id:) if issue_id
      entries = scope.to_a
      issues = entries.map(&:issue)
      evidence_by_issue_id = CloseoutEvidence.results_for(issues)
      technical_evidence_by_issue_id = TechnicalPrerequisites::Evidence.records_for_issues(issues)
      entries.map do |entry|
        attributes = entry.status.symbolize_keys.merge(
          evidence: evidence_by_issue_id.fetch(entry.issue_id),
          blockers: entry.blockers.map { |blocker| CloseoutStatus::Blocker.new(**blocker.symbolize_keys) },
          admissible: false,
          open_request: nil,
          resolved_current_generation: false,
          technical_evidence: technical_evidence_by_issue_id.fetch(entry.issue_id, [])
        )
        StalledCloseouts::Pair.new(issue: entry.issue, status: CloseoutStatus::Result.new(**attributes))
      end
    end
    private_class_method :projected_pairs

    def self.checkpointed_project_ids(projects)
      PartialCloseoutProjection.where(project_id: projects.map(&:id)).where.not(computed_at: nil).pluck(:project_id).to_set
    end
    private_class_method :checkpointed_project_ids

    def initialize(project:, stalled_closeouts:)
      @project = project
      @stalled_closeouts = stalled_closeouts
    end

    def call
      return unless FeatureFlags.enabled?(:partial_closeout_lane_read_model, project: project)

      failure = nil
      result = with_projection_advisory_lock do
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

    def with_projection_advisory_lock
      PartialCloseoutProjection.transaction do
        acquire_projection_advisory_lock
        yield
      end
    end

    def acquire_projection_advisory_lock
      lock_name = "#{ADVISORY_LOCK_NAMESPACE}:#{project.id}"
      PartialCloseoutProjection.connection.raw_connection.exec_params(ADVISORY_LOCK_SQL, [ lock_name ])
    end

    def replace_projection
      generation = SecureRandom.uuid
      input_snapshot = PartialCloseoutProjectionInputWatermark.for(project)
      pairs = stalled_closeouts.call([ project ])
      checkpoint = PartialCloseoutProjection.find_or_initialize_by(project: project)
      checkpoint.update!(computed_at: Time.current, generation:,
        input_watermark: input_snapshot.watermark, input_fingerprint: input_snapshot.fingerprint,
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
