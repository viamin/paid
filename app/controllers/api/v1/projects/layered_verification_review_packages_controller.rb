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
          page = package_page(@project.layered_verification_review_packages, limit: params[:limit], cursor: params[:cursor])
          response = { review_packages: page.records.map { |package| representation(package) } }
          response[:next_cursor] = page.next_cursor if page.next_cursor
          render json: response
        rescue ArgumentError => error
          render_error(:bad_request, :invalid_pagination, error.message)
        end

        def show
          authorize @project, :show?
          page = package_page(@package.lineage, limit: params[:lineage_limit], cursor: params[:lineage_cursor])
          response = representation(@package).merge(lineage: page.records.map { |package| representation(package) })
          response[:lineage_next_cursor] = page.next_cursor if page.next_cursor
          render json: response
        rescue ArgumentError => error
          render_error(:bad_request, :invalid_pagination, error.message)
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

        def package_page(relation, limit:, cursor:)
          LayeredVerification::ReviewPackages::Page.call(
            relation: relation.includes(:approvals),
            limit: integer_parameter(limit, default: LayeredVerification::ReviewPackages::Page::DEFAULT_LIMIT),
            cursor: integer_parameter(cursor)
          )
        end

        def integer_parameter(value, default: nil)
          return default if value.blank?

          Integer(value.to_s, 10)
        end
      end
    end
  end
end
