# frozen_string_literal: true

class Avo::Resources::AccountActivityEvent < Avo::BaseResource
  self.title = :id
  self.model_class = ::AccountActivityEvent
  self.authorization_policy = ::OperatorConsole::AccountActivityEventPolicy

  # @spec PROJECT-DELEGATION-001
  def fields
    field :id, as: :id
    field :account_id, as: :number, readonly: true
    field :action, as: :select, options: AccountActivityEvent::ACTION_CATEGORIES.keys.index_with(&:itself), readonly: true, sortable: true
    field :actor_id, as: :number, readonly: true
    field :subject_type, as: :text, readonly: true
    field :subject_id, as: :number, readonly: true
    field :metadata, as: :code, language: "json", pretty_generated: true, readonly: true
    field :created_at, as: :date_time, readonly: true, sortable: true
    field :updated_at, as: :date_time, readonly: true
  end
end
