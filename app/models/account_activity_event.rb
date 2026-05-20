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
      "Invited #{metadata_value('email')} as #{humanized_metadata_value('role')}"
    when "membership.role_changed"
      "Changed #{metadata_value('email')} from #{humanized_metadata_value('from_role')} to #{humanized_metadata_value('to_role')}"
    when "membership.removed"
      "Removed #{metadata_value('email')} from the account"
    when "ownership.transferred"
      "Transferred ownership to #{metadata_value('to_email')}"
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
      Array(metadata.to_h["changed_fields"]).map { |field| "#{field.humanize} changed" }
    when "ownership.transferred"
      [ "Previous owner: #{metadata_value('from_email')}" ]
    else
      []
    end
  end

  private

  def metadata_value(key)
    metadata.to_h[key] || "unknown"
  end

  def humanized_metadata_value(key)
    metadata_value(key).to_s.humanize.downcase
  end
end
