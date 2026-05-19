# frozen_string_literal: true

class AccountActivityEvent < ApplicationRecord
  belongs_to :account
  belongs_to :actor, class_name: "User", optional: true, inverse_of: :account_activity_events
  belongs_to :subject, polymorphic: true, optional: true

  validates :action, presence: true

  scope :recent, -> { order(created_at: :desc) }

  def actor_label
    actor&.email || "System"
  end

  def description
    case action
    when "account.updated"
      "Updated account settings"
    when "membership.invited"
      "Invited #{metadata.fetch('email')} as #{metadata.fetch('role').humanize.downcase}"
    when "membership.role_changed"
      "Changed #{metadata.fetch('email')} from #{metadata.fetch('from_role').humanize.downcase} to #{metadata.fetch('to_role').humanize.downcase}"
    when "membership.removed"
      "Removed #{metadata.fetch('email')} from the account"
    when "ownership.transferred"
      "Transferred ownership to #{metadata.fetch('to_email')}"
    when "lifecycle.suspended"
      "Suspended the account"
    when "lifecycle.reactivated"
      "Reactivated the account"
    when "lifecycle.deactivated"
      "Deactivated the account"
    when "tenant_configuration.updated"
      "Updated tenant configuration"
    else
      action.humanize
    end
  end

  def detail_lines
    case action
    when "account.updated", "tenant_configuration.updated"
      Array(metadata["changed_fields"]).map { |field| "#{field.humanize} changed" }
    when "ownership.transferred"
      [ "Previous owner: #{metadata['from_email']}" ]
    else
      []
    end
  end
end
