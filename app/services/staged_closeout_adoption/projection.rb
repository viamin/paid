# frozen_string_literal: true

module StagedCloseoutAdoption
  # Shared inspectable read model for operator and agent/API surfaces.
  # @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-004 STAGED-CLOSEOUT-ADOPTION-014
  class Projection
    MAPPING_FIELDS = %w[
      id issue_id criterion_key stage phase target_shape execution_path target_key target_version target_digest
      environment_class freshness_seconds retry_policy status revision reviewed_by_id reviewed_at
      invalidated_by_id invalidated_at invalidation_reason
    ].freeze

    def self.for_project(project) = new(project).to_h

    def initialize(project)
      @project = project
    end

    def to_h
      { enrollment:, mappings: mapping_results.map { |result| serialize(result) },
        automatic_run_reason: automatic_run_reason }
    end

    private

    attr_reader :project

    def enrollment
      project.staged_closeout_enrollment&.slice(:enabled, :reviewed_by_id, :reviewed_at, :revision) || { enabled: false }
    end

    def mappings
      @mappings ||= project.staged_closeout_mappings.includes(:issue).order(:issue_id, :criterion_key, :revision)
    end

    def mapping_results
      @mapping_results ||= mappings.map do |mapping|
        Mappings.eligible_for(mapping:, project:, issue: mapping.issue)
      end
    end

    def serialize(result)
      result.mapping.slice(*MAPPING_FIELDS).merge("eligibility_reason" => result.reason)
    end

    def automatic_run_reason
      return "project_not_enrolled" unless project.staged_closeout_enrollment&.enabled?
      return "no_approved_mapping" if mapping_results.empty?
      eligible = mapping_results.find(&:eligible?)
      return waiting_reason(eligible.mapping) if eligible

      current_result.reason
    end

    def waiting_reason(mapping)
      return "waiting_for_source_pr_verification" if mapping.stage == "pre_merge"

      run = AgentRun.where(project:, issue_id: mapping.issue_id, closeout_mapping_id: mapping.id,
        goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL, synthetic: true).order(id: :desc).first
      return "verification_#{run.status}" if run&.status.in?(%w[queued running])
      return "waiting_for_current_verification" if run

      mapping.stage == "merged_revision" ? "waiting_for_merge_observation" : "waiting_for_environment_signal"
    end

    def current_result
      mapping_results.reverse.find { |result| result.mapping.current? } || mapping_results.last
    end
  end
end
