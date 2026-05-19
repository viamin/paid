# frozen_string_literal: true

class Avo::Resources::ProjectMembership < Avo::BaseResource
  self.title = :id
  self.model_class = ::ProjectMembership
  self.authorization_policy = ::OperatorConsole::ProjectMembershipPolicy

  def fields
    field :id, as: :id
    field :project_id, as: :number
    field :user_id, as: :number
    field :role, as: :select, options: ProjectMembership.roles.keys.index_with(&:itself), sortable: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
