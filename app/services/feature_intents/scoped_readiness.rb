# frozen_string_literal: true

module FeatureIntents
  # Deterministically evaluates an agent-authored prerequisite map. Semantic
  # judgment belongs to the assessor; this boundary only verifies coverage,
  # freshness, independent score thresholds, and the relevant design baseline.
  # It is deliberately shadow-only until the complete RDR-071 release path is
  # wired, so callers cannot turn a passing assessment into run eligibility.
  # @spec FACET-CONFIDENCE-008 FACET-CONFIDENCE-009 FACET-CONFIDENCE-010
  # @spec FACET-CONFIDENCE-011 FACET-CONFIDENCE-012 CONFIDENCE-DELIVERY-003
  # @spec CONFIDENCE-DELIVERY-014
  class ScopedReadiness
    Blocker = Data.define(:code, :message, :prerequisite_id, :artifact_path)
    Result = Data.define(:ready, :blockers, :snapshot) do
      def ready? = ready
      def shadow_only? = true
      def releasable? = false
    end

    COMPLETE_ASSESSMENT_STATUSES = %w[completed succeeded].freeze

    def self.call(...) = new(...).call

    def initialize(project:, mapping:)
      @project = project
      @mapping = mapping.to_h.deep_stringify_keys
    end

    def call
      blockers = coverage_blockers + prerequisite_blockers + design_artifact_blockers
      Result.new(ready: blockers.empty?, blockers:, snapshot: readiness_snapshot)
    end

    private

    attr_reader :mapping, :project

    def coverage_blockers
      return [] if coverage_complete?

      [ blocker("prerequisite_coverage_unknown", "Material prerequisite coverage has not been confirmed.") ]
    end

    def prerequisite_blockers
      return [] unless coverage_complete?

      prerequisites.flat_map { |prerequisite| blockers_for(prerequisite) }
    end

    def blockers_for(prerequisite)
      assessment = prerequisite.fetch("assessment", {}).to_h
      return [ prerequisite_blocker("assessment_missing", prerequisite, "has no current assessment.") ] if assessment.empty?
      return [ prerequisite_blocker("assessment_#{assessment.fetch("status", "unknown")}", prerequisite, "assessment is not complete.") ] unless assessment_complete?(assessment)
      return [ prerequisite_blocker("assessment_superseded", prerequisite, "assessment targets superseded evidence.") ] unless current_evidence?(assessment)

      score_blockers(prerequisite, assessment)
    end

    def score_blockers(prerequisite, assessment)
      [
        score_blocker("intent", assessment["intent_score"], intent_threshold, prerequisite),
        score_blocker("technical", assessment["technical_score"], technical_threshold, prerequisite)
      ].compact
    end

    def score_blocker(axis, score, threshold, prerequisite)
      return prerequisite_blocker("#{axis}_unknown", prerequisite, "#{axis} score is unknown.") unless score.is_a?(Numeric)
      return if score >= threshold

      prerequisite_blocker("#{axis}_below_threshold", prerequisite, "#{axis} score #{score} is below threshold #{threshold}.")
    end

    def design_artifact_blockers
      required_design_artifacts.flat_map { |artifact| blockers_for_artifact(artifact) }
    end

    def blockers_for_artifact(artifact)
      return [ artifact_blocker("design_artifact_unmerged", artifact, "has not merged.") ] unless artifact["merged"] == true
      return [ artifact_blocker("design_artifact_revision_unknown", artifact, "has no merged revision.") ] if artifact["revision"].blank?
      return [] if artifact["scope_revision"] == scope_revision

      [ artifact_blocker("design_artifact_scope_mismatch", artifact, "does not express the current issue scope.") ]
    end

    def coverage_complete? = mapping["coverage"] == "complete" || mapping["coverage_complete"] == true
    def prerequisites = Array(mapping["prerequisites"])
    def required_design_artifacts = Array(mapping["design_artifacts"]).select { |artifact| artifact["required"] == true }
    def assessment_complete?(assessment) = COMPLETE_ASSESSMENT_STATUSES.include?(assessment["status"])
    def current_evidence?(assessment) = assessment["evidence_revision"].present? && assessment["current_evidence_revision"].in?([ nil, assessment["evidence_revision"] ])
    def scope_revision = mapping["scope_revision"]
    def intent_threshold = project.intent_threshold
    def technical_threshold = project.technical_threshold

    def blocker(code, message, prerequisite_id: nil, artifact_path: nil)
      Blocker.new(code:, message:, prerequisite_id:, artifact_path:)
    end

    def prerequisite_blocker(code, prerequisite, detail)
      id = prerequisite["id"].presence || "unnamed prerequisite"
      blocker(code, "Prerequisite #{id} #{detail}", prerequisite_id: prerequisite["id"])
    end

    def artifact_blocker(code, artifact, detail)
      path = artifact["path"].presence || "unnamed design artifact"
      blocker(code, "Design artifact #{path} #{detail}", artifact_path: artifact["path"])
    end

    def readiness_snapshot
      {
        "scope_revision" => scope_revision,
        "thresholds" => { "intent" => intent_threshold, "technical" => technical_threshold },
        "prerequisites" => prerequisites.map { |prerequisite| snapshot_prerequisite(prerequisite) },
        "design_artifacts" => required_design_artifacts.map { |artifact| artifact.slice("path", "revision", "scope_revision", "merged") }
      }
    end

    def snapshot_prerequisite(prerequisite)
      assessment = prerequisite.fetch("assessment", {}).to_h
      prerequisite.slice("id", "rationale").merge(
        "assessment_status" => assessment["status"],
        "evidence_revision" => assessment["evidence_revision"],
        "current_evidence_revision" => assessment["current_evidence_revision"],
        "intent_score" => assessment["intent_score"],
        "technical_score" => assessment["technical_score"]
      )
    end
  end
end
