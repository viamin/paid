# frozen_string_literal: true

module Api
  module V1
    # Read-only, project-authorized surface for traceability gaps. Repairs use
    # the existing issue and design-PR write paths after an operator inspects
    # the cited evidence.
    # @spec DESIGN-RECONCILIATION-001
    class DesignArtifactFindingsController < BaseController
      before_action -> { require_scope!(:inbox) }

      def index
        project = policy_scope(Project).find(params[:project_id])
        authorize project, :show?

        findings = project.design_artifact_findings.open_findings.order(created_at: :desc)
        render json: { findings: findings.map { |finding| serialize(finding) } }
      end

      private

      def serialize(finding)
        {
          id: finding.id,
          artifact_path: finding.artifact_path,
          revision: finding.revision,
          state: finding.state,
          evidence: finding.evidence,
          covered_at: finding.covered_at.iso8601
        }
      end
    end
  end
end
