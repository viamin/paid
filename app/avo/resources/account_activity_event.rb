# frozen_string_literal: true

class Avo::Resources::AccountActivityEvent < Avo::BaseResource
  self.title = :id
  self.model_class = ::AccountActivityEvent
  self.authorization_policy = ::OperatorConsole::AccountActivityEventPolicy

  def fields
    field :id, as: :id
    field :account_id, as: :number
    field :action, as: :select, options: AccountActivityEvent::ACTION_CATEGORIES.keys.index_with(&:itself), sortable: true
    field :actor_id, as: :number
    field :subject_type, as: :text
    field :subject_id, as: :number
    field :metadata, as: :code, language: "json", pretty_generated: true
    field :created_at, as: :date_time, readonly: true, sortable: true
    field :updated_at, as: :date_time, readonly: true
  end
end
