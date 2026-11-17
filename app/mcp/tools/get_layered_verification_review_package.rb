# frozen_string_literal: true

module Tools
  class GetLayeredVerificationReviewPackage < ListLayeredVerificationReviewPackages
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "get_layered_verification_review_package"

    def self.description
      "Get one immutable layered-verification business-review package and its revision lineage."
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, review_package_id: { type: "integer" } }, required: %w[project_id review_package_id] }
    end

    # @spec LAYERED-VERIFY-012
    # @spec LAYERED-VERIFY-023
    def perform(project_id:, review_package_id:)
      package = project_for(project_id).layered_verification_review_packages.includes(:approvals).find(review_package_id)
      LayeredVerification::ReviewPackages::Representation.package(package).merge(
        lineage: package.lineage.includes(:approvals).order(:revision_number).map { |revision| LayeredVerification::ReviewPackages::Representation.package(revision) }
      )
    end
  end
end
