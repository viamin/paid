# frozen_string_literal: true

module Tools
  class ListLayeredVerificationReviewPackages < BaseTool
    authorize :show?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "list_layered_verification_review_packages"

    def self.description
      "List immutable layered-verification business-review package history for an authorized project."
    end

    def self.input_schema
      { type: "object", properties: { project_id: { type: "integer" } }, required: [ "project_id" ] }
    end

    def self.available_for_project?(user:, project:)
      FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :show?, policy_class: ProjectPolicy)
    end

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project| available_for_project?(user:, project:) }
    end

    # @spec LAYERED-VERIFY-012
    # @spec LAYERED-VERIFY-023
    def perform(project_id:)
      project_for(project_id).layered_verification_review_packages.includes(:approvals).order(:agent_run_id, :revision_number)
        .map { |package| LayeredVerification::ReviewPackages::Representation.package(package) }
    end

    private

    def project_for(id)
      @projects_by_id ||= {}
      @projects_by_id[id] ||= policy_scope(Project).find(id).tap do |project|
        raise LayeredVerification::AuditAccess::FeatureDisabledError, "layered verification is not enabled for this project" unless FeatureFlags.enabled?(:layered_verification_add_on, project:)
      end
    end
  end
end
