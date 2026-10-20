# frozen_string_literal: true

module Api
  module V1
    # @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
    class DesignArtifactFindingsController < BaseController
      before_action -> { require_scope!(:inbox) }

      def index
        project = policy_scope(Project).find(params[:project_id])
        authorize project, :show?

        findings = project.design_artifact_findings.open_findings.order(created_at: :desc)
        render json: { findings: findings.map { |finding| serialize(finding) } }
      end

      def resolve
        project = policy_scope(Project).find(params[:project_id])
        authorize project, :manage_issues?, policy_class: ProjectPolicy
        finding = project.design_artifact_findings.find(params[:id])
        issue = project.issues.find_by(id: resolution_params[:issue_id]) if resolution_params[:issue_id].present?
        DesignArtifactFindings::Resolve.call(finding:, user: current_user, issue:, **resolution_params.except(:issue_id).symbolize_keys)
        render json: { finding: serialize(finding) }
      rescue ArgumentError => e
        render_error(:unprocessable_entity, :invalid_resolution, e.message)
      end

      def recheck
        project = policy_scope(Project).find(params[:project_id])
        authorize project, :manage_issues?, policy_class: ProjectPolicy
        finding = project.design_artifact_findings.find(params[:id])
        raise ArgumentError, "finding changed; reload before rechecking" unless finding.revision == params.require(:revision).to_s

        finding.update!(status: "open", resolution_state: nil, resolution_reason: nil, resolution_actor: nil,
          resolution_issue: nil, resolution_metadata: {})
        render json: { finding: serialize(finding) }
      rescue ArgumentError => e
        render_error(:unprocessable_entity, :invalid_resolution, e.message)
      end

      private

      def serialize(finding)
        {
          id: finding.id,
          artifact_path: finding.artifact_path,
          revision: finding.revision,
          state: finding.state,
          evidence: finding.evidence,
          covered_at: finding.covered_at.iso8601,
          status: finding.status,
          resolution_state: finding.resolution_state,
          resolution_reason: finding.resolution_reason,
          resolution_issue_id: finding.resolution_issue_id
        }
      end

      def resolution_params
        params.require(:resolution).permit(:state, :reason, :revision, :issue_id)
      end
    end
  end
end
