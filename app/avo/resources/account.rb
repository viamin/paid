# frozen_string_literal: true

class Avo::Resources::Account < Avo::BaseResource
  self.title = :name
  self.model_class = ::Account
  self.authorization_policy = ::OperatorConsole::AccountPolicy

  def fields
    field :id, as: :id
    field :name, as: :text, sortable: true
    field :slug, as: :text, sortable: true
    field :plan, as: :select, options: Account::PLANS.index_with(&:itself), sortable: true
    field :status, as: :select, options: Account.statuses.keys.index_with(&:itself), sortable: true
    field :default_max_tokens_per_run, as: :number
    field :trial_ends_at, as: :date_time
    field :onboarding_completed_at, as: :date_time
    field :scheduler_paused_at, as: :date_time, readonly: true
    field :suspended_at, as: :date_time, readonly: true
    field :deactivated_at, as: :date_time, readonly: true
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end

  def actions
    action Avo::Actions::SuspendAccount
    action Avo::Actions::ReactivateAccount
    action Avo::Actions::DeactivateAccount
  end
end
