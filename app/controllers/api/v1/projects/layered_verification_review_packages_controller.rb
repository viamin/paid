# frozen_string_literal: true

module Api
  module V1
    module Projects
      # Authenticated inspection and explicitly confirmed business-review
      # approval. This never dispatches repair, release, or rollout work.
      # @spec LAYERED-VERIFY-012
      # @spec LAYERED-VERIFY-023
      class LayeredVerificationReviewPackagesController < BaseController
        before_action -> { require_scope!(:inbox) }
        before_action :set_project
        before_action :require_layered_verification!
        before_action :set_package, only: %i[show approve]

        def index
          authorize @project, :show?
          packages = @project.layered_verification_review_packages.includes(:approvals).order(:agent_run_id, :revision_number)
          render json: { review_packages: packages.map { |package| representation(package) } }
        end

        def show
          authorize @project, :show?
          render json: representation(@package).merge(lineage: @package.lineage.includes(:approvals).order(:revision_number).map { |package| representation(package) })
        end

        def approve
          authorize @project, :manage_issues?
          return render_error(:unprocessable_content, :confirmation_required, "Confirmation required: set confirmed=true to record business-review approval") unless params[:confirmed] == true

          approval = LayeredVerification::ReviewPackages::Approve.call(
            package: @package, user: current_user, provenance: { "surface" => "api", "note" => params[:note] }
          )
          render json: { approval: LayeredVerification::ReviewPackages::Representation.approval(approval), package: representation(approval.package) }, status: :created
        rescue LayeredVerification::ReviewPackages::Approve::StalePackageError => error
          render_error(:unprocessable_content, :stale_review_package, error.message)
        rescue LayeredVerification::AuditAccess::FeatureDisabledError => error
          render_error(:unprocessable_content, :layered_verification_unavailable, error.message)
        rescue LayeredVerification::AuditAccess::UnauthorizedError
          render_error(:forbidden, :forbidden, "You are not authorized to perform this action.")
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def set_package
          @package = @project.layered_verification_review_packages.find(params[:id])
        end

        def require_layered_verification!
          return if FeatureFlags.enabled?(:layered_verification_add_on, project: @project)

          render_error(:unprocessable_content, :layered_verification_unavailable, "layered verification is not enabled for this project")
        end

        def representation(package)
          LayeredVerification::ReviewPackages::Representation.package(package)
        end
      end
    end
  end
end
