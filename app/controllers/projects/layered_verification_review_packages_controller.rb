# frozen_string_literal: true

module Projects
  # Inspectable business-review package history for a project, plus the
  # separately authorized business-review approval path. Approval records the
  # reviewer's decision at the bound revision only; it never starts a repair
  # or authorizes a release.
  # @spec LAYERED-VERIFY-023
  class LayeredVerificationReviewPackagesController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project
    before_action :require_layered_verification!
    before_action :set_package, only: [ :show, :approve ]

    def index
      authorize @project, :show?

      @packages = @project.layered_verification_review_packages
        .includes(:approvals, approvals: :approved_by, agent_run: :project)
        .order(:agent_run_id, :revision_number)

      respond_to do |format|
        format.html
        format.json { render json: @packages.map { |package| package_json(package) } }
      end
    end

    def show
      authorize @package.project, :show?

      @lineage = @package.lineage.includes(:approvals, approvals: :approved_by).order(:revision_number)
    end

    # The same authorization bar as the audit request surface; approval binds
    # only the reviewer's business-intent validation decision.
    def approve
      authorize @project, :manage_issues?

      approval = LayeredVerification::ReviewPackages::Approve.call(
        package: @package, user: current_user, provenance: { "surface" => "ui", "note" => params[:note] }
      )

      redirect_to project_layered_verification_review_package_path(@project, approval.package),
        notice: "Business-review approval recorded at the bound revision."
    rescue LayeredVerification::ReviewPackages::Approve::StalePackageError,
           LayeredVerification::AuditAccess::FeatureDisabledError,
           LayeredVerification::AuditAccess::UnauthorizedError => e
      redirect_to project_layered_verification_review_package_path(@project, @package), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_package
      @package = @project.layered_verification_review_packages.find(params[:id])
    end

    # @spec LAYERED-VERIFY-012 — one entry-point guard, no second flag.
    def require_layered_verification!
      return if FeatureFlags.enabled?(:layered_verification_add_on, project: @project)

      redirect_to project_path(@project), alert: "layered verification is not enabled for this project"
    end

    def package_json(package)
      {
        id: package.id, agent_run_id: package.agent_run_id, revision_number: package.revision_number,
        package_digest: package.package_digest, bound_inputs: package.bound_inputs,
        approvals: package.approvals.map { |approval| approval_json(approval) }
      }
    end

    def approval_json(approval)
      { id: approval.id, approved_by_id: approval.approved_by_id,
        approved_at: approval.approved_at.iso8601, provenance: approval.provenance }
    end
  end
end
