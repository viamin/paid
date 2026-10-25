# frozen_string_literal: true

module Tools
  # Cancels an active prerequisite-evidence validation. Evidence collected so
  # far is preserved and the provisioned environment is still cleaned up.
  # @spec PREREQ-EVIDENCE-007
  class CancelPrerequisiteValidation < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "cancel_prerequisite_validation"
    def self.write_operation? = true
    def self.description
      "Cancel an active execution-evidence validation for a project. Collected evidence is preserved and " \
        "the isolated environment is cleaned up. Requires confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          validation_id: { type: "integer", description: "The prerequisite validation ID" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id validation_id confirmed]
      }
    end

    def perform(project_id:, validation_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to cancel a prerequisite validation" unless confirmed

      project = project_for(project_id)
      result = Prerequisites::CancelValidation.call(project.prerequisite_validations.find(validation_id))
      raise ArgumentError, result.message unless result.success?

      { id: result.validation.id, status: result.validation.status }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
