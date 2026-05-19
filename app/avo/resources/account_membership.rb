# frozen_string_literal: true

class Avo::Resources::AccountMembership < Avo::BaseResource
  self.title = :id
  self.model_class = ::AccountMembership
  self.authorization_policy = ::OperatorConsole::AccountMembershipPolicy

  def fields
    field :id, as: :id
    field :account_id, as: :number
    field :user_id, as: :number
    field :role, as: :select, options: AccountMembership.roles.keys.index_with(&:itself), sortable: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
