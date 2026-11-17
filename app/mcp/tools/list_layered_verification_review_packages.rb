# frozen_string_literal: true

module Tools
  class ListLayeredVerificationReviewPackages < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "list_layered_verification_review_packages"

    def self.description
      "List immutable layered-verification business-review package history for an authorized project."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          limit: { type: "integer", minimum: 1, maximum: LayeredVerification::ReviewPackages::Page::MAX_LIMIT,
                   default: LayeredVerification::ReviewPackages::Page::DEFAULT_LIMIT },
          cursor: { type: "integer", minimum: 1, description: "Package ID returned as next_cursor by a previous call" }
        },
        required: [ "project_id" ]
      }
    end

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :show?, policy_class: ProjectPolicy)
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    end

    # @spec LAYERED-VERIFY-012
    # @spec LAYERED-VERIFY-023
    def perform(project_id:, limit: LayeredVerification::ReviewPackages::Page::DEFAULT_LIMIT, cursor: nil)
      page = package_page(project_for(project_id).layered_verification_review_packages, limit:, cursor:)
      response = { review_packages: page.records.map { |package| representation(package) } }
      response[:next_cursor] = page.next_cursor if page.next_cursor
      response
    end

    private

    def package_page(relation, limit:, cursor:)
      LayeredVerification::ReviewPackages::Page.call(relation: relation.includes(:approvals), limit:, cursor:)
    end

    def representation(package)
      LayeredVerification::ReviewPackages::Representation.package(package)
    end

    def project_for(id)
      @projects_by_id ||= {}
      @projects_by_id[id] ||= policy_scope(Project).find(id).tap do |project|
        raise LayeredVerification::AuditAccess::FeatureDisabledError, "layered verification is not enabled for this project" unless FeatureFlags.enabled?(:layered_verification_add_on, project:)
      end
    end
  end
end
