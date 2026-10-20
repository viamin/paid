# frozen_string_literal: true

# @spec OPERATOR-INBOX-018 DESIGN-RECONCILIATION-001
class DesignArtifactFindingsController < ApplicationController
  def resolve
    finding = DesignArtifactFinding.find(params[:id])
    authorize finding.project, :manage_issues?, policy_class: ProjectPolicy
    issue = finding.project.issues.find_by(id: resolution_params[:issue_id]) if resolution_params[:issue_id].present?
    DesignArtifactFindings::Resolve.call(
      finding:, user: current_user, issue:, state: resolution_params[:state],
      reason: resolution_params[:reason], revision: resolution_params[:revision]
    )
    redirect_to inbox_path, notice: "Traceability decision recorded. Recheck after the cited work changes."
  rescue ArgumentError => e
    redirect_back fallback_location: inbox_path, alert: e.message
  end

  def file_issue
    finding = DesignArtifactFinding.find(params[:id])
    authorize finding.project, :manage_issues?, policy_class: ProjectPolicy
    issue = DesignArtifactFindings::FileIssue.call(
      finding:, user: current_user, title: file_issue_params[:title], body: file_issue_params[:body],
      revision: file_issue_params[:revision]
    )
    redirect_to project_path(finding.project, anchor: "issue_#{issue.id}"),
      notice: "Filed ##{issue.github_number} and linked the finding to it. Recheck after the cited work changes."
  rescue ArgumentError => e
    redirect_back fallback_location: inbox_entry_path("traceability_gap:#{params[:id]}"), alert: e.message
  rescue GithubClient::Error => e
    Rails.logger.warn(
      message: "design_artifact_findings.file_issue_failed",
      finding_id: finding.id, project_id: finding.project_id, error: e.message
    )
    redirect_back fallback_location: inbox_entry_path("traceability_gap:#{params[:id]}"),
      alert: "GitHub rejected the new issue: #{e.message}"
  end

  def recheck
    finding = DesignArtifactFinding.find(params[:id])
    authorize finding.project, :manage_issues?, policy_class: ProjectPolicy
    raise ArgumentError, "finding changed; reload before rechecking" unless finding.revision == params[:revision].to_s

    finding.update!(status: "open", resolution_state: nil, resolution_reason: nil, resolution_actor: nil,
      resolution_issue: nil, resolution_metadata: {})
    redirect_to inbox_entry_path("traceability_gap:#{finding.id}"), notice: "Finding returned to the action queue for revalidation."
  rescue ArgumentError => e
    redirect_back fallback_location: inbox_path, alert: e.message
  end

  private

  def resolution_params
    params.require(:resolution).permit(:state, :reason, :revision, :issue_id)
  end

  def file_issue_params
    params.require(:filing).permit(:title, :body, :revision)
  end
end
