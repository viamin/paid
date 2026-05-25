# frozen_string_literal: true

class Avo::Resources::PreCommitRequirement < Avo::BaseResource
  self.title = :name
  self.model_class = ::PreCommitRequirement
  self.authorization_policy = ::OperatorConsole::PreCommitRequirementPolicy

  def fields
    field :id, as: :id
    field :name, as: :text, sortable: true
    field :check_type, as: :select, options: PreCommitRequirement::CHECK_TYPES.index_with(&:itself), sortable: true
    field :command, as: :textarea
    field :failure_behavior, as: :select, options: PreCommitRequirement::FAILURE_BEHAVIORS.index_with(&:itself), sortable: true
    field :enabled, as: :boolean, sortable: true
    field :position, as: :number, sortable: true
    field :account_id, as: :number
    field :project_id, as: :number
    field :user_id, as: :number
    field :fix_command, as: :text
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
