# frozen_string_literal: true

class AccountActivityEvent < ApplicationRecord
  ACTION_CATEGORIES = {
    "account.updated" => "account",
    "account.deleted" => "account",
    "membership.invited" => "membership",
    "membership.role_changed" => "membership",
    "membership.removed" => "membership",
    "ownership.transferred" => "membership",
    "lifecycle.suspended" => "lifecycle",
    "lifecycle.reactivated" => "lifecycle",
    "lifecycle.deactivated" => "lifecycle",
    "tenant_configuration.updated" => "settings",
    "compliance.assurance_updated" => "settings",
    "project.created" => "project",
    "project.updated" => "project",
    "project.deleted" => "project",
    "project.settings_changed" => "project",
    "runner.created" => "runner",
    "runner.updated" => "runner",
    "runner.deleted" => "runner",
    "agent_run.created" => "run",
    "agent_run.cancelled" => "run",
    "agent_run.retried" => "run",
    "agent_run.terminated" => "run",
    "agent_run.resumed" => "run",
    "prompt_version.approved" => "approval",
    "prompt_version.rejected" => "approval",
    "auth.sign_in" => "auth",
    "auth.password_changed" => "auth"
  }.freeze

  belongs_to :account
  belongs_to :actor, class_name: "User", optional: true, inverse_of: :account_activity_events
  belongs_to :subject, polymorphic: true, optional: true

  validates :action, presence: true
  validates :action, inclusion: { in: ACTION_CATEGORIES.keys }, allow_blank: true

  scope :recent, -> { order(created_at: :desc) }
  scope :by_action, ->(action) { where(action: action) }
  scope :by_category, ->(category) { where(action: actions_for_category(category)) }
  scope :searchable, ->(q) { where("metadata::text ILIKE ?", "%#{q}%") }

  def self.ransackable_attributes(_auth_object = nil)
    %w[
      action
      actor_id
      created_at
      id
      metadata
      subject_id
      subject_type
      updated_at
    ]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[actor]
  end

  def self.actions_for_category(category)
    ACTION_CATEGORIES.select { |_, cat| cat == category.to_s }.keys
  end

  def actor_label
    actor&.email || "System"
  end

  def category
    ACTION_CATEGORIES[action] || "other"
  end

  def description
    case action
    when "account.updated"
      "Updated account settings"
    when "account.deleted"
      "Deleted account"
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
    when "compliance.assurance_updated"
      "Updated compliance and deployment assurance settings"
    when "project.created"
      "Created project #{metadata_value('name')}"
    when "project.updated"
      "Updated project #{metadata_value('name')}"
    when "project.deleted"
      "Deleted project #{metadata_value('name')}"
    when "project.settings_changed"
      "Changed project #{metadata_value('name')} settings"
    when "runner.created"
      "Added #{metadata_value('runner_name')} runner"
    when "runner.updated"
      "Updated #{metadata_value('runner_name')} runner"
    when "runner.deleted"
      "Removed #{metadata_value('runner_name')} runner"
    when "agent_run.created"
      "Created agent run ##{metadata_value('agent_run_id')} on #{metadata_value('project_name')}"
    when "agent_run.cancelled"
      "Cancelled agent run ##{metadata_value('agent_run_id')}"
    when "agent_run.retried"
      "Retried agent run ##{metadata_value('agent_run_id')} -> ##{metadata_value('new_agent_run_id')}"
    when "agent_run.terminated"
      "Terminated agent run ##{metadata_value('agent_run_id')}"
    when "agent_run.resumed"
      "Resumed agent run ##{metadata_value('agent_run_id')}"
    when "prompt_version.approved"
      "Approved prompt #{metadata_value('prompt_slug')} v#{metadata_value('version')}"
    when "prompt_version.rejected"
      "Rejected prompt #{metadata_value('prompt_slug')} v#{metadata_value('version')}"
    when "auth.sign_in"
      "Signed in"
    when "auth.password_changed"
      "Changed password"
    else
      action.humanize
    end
  end

  def detail_lines
    case action
    when "account.updated", "tenant_configuration.updated", "compliance.assurance_updated"
      Array(metadata.to_h["changed_fields"]).map { |field| "#{field.humanize} changed" }
    when "ownership.transferred"
      [ "Previous owner: #{metadata_value('from_email')}" ]
    when "project.updated", "project.settings_changed"
      Array(metadata.to_h["changed_fields"]).map { |field| "#{field.to_s.humanize} changed" }
    when "project.created"
      Array(metadata.to_h["github_url"]).compact
    when "runner.created", "runner.updated"
      Array(metadata.to_h["details"]).compact
    when "agent_run.created"
      Array(metadata.to_h["details"]).compact
    when "agent_run.retried"
      Array(metadata.to_h["details"]).compact
    when "prompt_version.approved"
      Array(metadata.to_h["notes"]).compact.map { |n| "Notes: #{n}" }
    when "prompt_version.rejected"
      Array(metadata.to_h["notes"]).compact.map { |n| "Notes: #{n}" }
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
