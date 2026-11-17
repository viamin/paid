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

      respond_to do |format|
        format.html
        format.json { render json: package_json(@package).merge(lineage: @lineage.map { |package| package_json(package) }) }
      end
    end

    # The same authorization bar as the audit request surface; approval binds
    # only the reviewer's business-intent validation decision.
    def approve
      authorize @project, :manage_issues?

      approval = LayeredVerification::ReviewPackages::Approve.call(
        package: @package, user: current_user, provenance: { "surface" => "ui", "note" => params[:note] }
      )

      respond_to do |format|
        format.html do
          redirect_to project_layered_verification_review_package_path(@project, approval.package),
            notice: "Business-review approval recorded at the bound revision."
        end
        format.json { render json: { approval: approval_json(approval), package: package_json(approval.package) }, status: :created }
      end
    rescue LayeredVerification::ReviewPackages::Approve::StalePackageError,
           LayeredVerification::AuditAccess::FeatureDisabledError,
           LayeredVerification::AuditAccess::UnauthorizedError => e
      respond_to do |format|
        format.html { redirect_to project_layered_verification_review_package_path(@project, @package), alert: e.message }
        format.json { render json: { error: { code: "stale_review_package", message: e.message } }, status: :unprocessable_content }
      end
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
      LayeredVerification::ReviewPackages::Representation.package(package)
    end

    def approval_json(approval)
      LayeredVerification::ReviewPackages::Representation.approval(approval)
    end
  end
end
