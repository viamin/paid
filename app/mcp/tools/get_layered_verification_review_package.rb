# frozen_string_literal: true

module Tools
  class GetLayeredVerificationReviewPackage < ListLayeredVerificationReviewPackages
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "get_layered_verification_review_package"

    def self.description
      "Get one immutable layered-verification business-review package and its revision lineage."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          review_package_id: { type: "integer" },
          lineage_limit: { type: "integer", minimum: 1, maximum: LayeredVerification::ReviewPackages::Page::MAX_LIMIT,
                           default: LayeredVerification::ReviewPackages::Page::DEFAULT_LIMIT },
          lineage_cursor: { type: "integer", minimum: 1, description: "Package ID returned as lineage_next_cursor by a previous call" }
        },
        required: %w[project_id review_package_id]
      }
    end

    # @spec LAYERED-VERIFY-012
    # @spec LAYERED-VERIFY-023
    def perform(project_id:, review_package_id:, lineage_limit: LayeredVerification::ReviewPackages::Page::DEFAULT_LIMIT,
      lineage_cursor: nil)
      package = project_for(project_id).layered_verification_review_packages.includes(:approvals).find(review_package_id)
      page = package_page(package.lineage, limit: lineage_limit, cursor: lineage_cursor)
      response = representation(package).merge(lineage: page.records.map { |revision| representation(revision) })
      response[:lineage_next_cursor] = page.next_cursor if page.next_cursor
      response
    end
  end
end
