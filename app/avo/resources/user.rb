# frozen_string_literal: true

class Avo::Resources::User < Avo::BaseResource
  self.title = :email
  self.model_class = ::User
  self.authorization_policy = ::OperatorConsole::UserPolicy

  def fields
    field :id, as: :id
    field :email, as: :text, sortable: true
    field :name, as: :text, sortable: true
    field :account_id, as: :number
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
    field :remember_created_at, as: :date_time, readonly: true, hide_on: :forms
  end
end
