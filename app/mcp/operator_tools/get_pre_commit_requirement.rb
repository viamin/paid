# frozen_string_literal: true

module OperatorTools
  class GetPreCommitRequirement < ResourceGetTool
    authorize :show?, ->(args) { PreCommitRequirement.find(args.fetch(:id)) }, policy_class: OperatorConsole::PreCommitRequirementPolicy

    def self.tool_name = "operator_get_pre_commit_requirement"
    def self.model_class = PreCommitRequirement
    def self.policy_class = OperatorConsole::PreCommitRequirementPolicy
    def self.resource_label = "pre-commit requirement"
    def self.attributes = %i[
      id name check_type command failure_behavior enabled position account_id project_id user_id fix_command
      created_at updated_at
    ]
  end
end
