# frozen_string_literal: true

module Tools
  class ApproveLayeredVerificationReviewPackage < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "approve_layered_verification_review_package"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Record an explicitly confirmed, revision-bound business-review approval. This never starts repair or authorizes release."
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" }, review_package_id: { type: "integer" }, note: { type: "string" }, confirmed: { type: "boolean" } }, required: %w[project_id review_package_id confirmed] }
    end

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    end

    # @spec LAYERED-VERIFY-012
    # @spec LAYERED-VERIFY-023
    def perform(project_id:, review_package_id:, confirmed: nil, note: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to record business-review approval" unless confirmed == true

      package = project_for(project_id).layered_verification_review_packages.find(review_package_id)
      approval = LayeredVerification::ReviewPackages::Approve.call(
        package:, user: current_user, provenance: { "surface" => "mcp", "note" => note }
      )
      { approval: LayeredVerification::ReviewPackages::Representation.approval(approval), package: LayeredVerification::ReviewPackages::Representation.package(approval.package) }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
