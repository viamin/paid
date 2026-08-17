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
    "operations.dashboard_updated" => "settings",
    "project.created" => "project",
    "project.updated" => "project",
    "project.deleted" => "project",
    "project.settings_changed" => "project",
    "issue.created" => "project",
    "issue.updated" => "project",
    "issue.labels_changed" => "project",
    "runner.created" => "runner",
    "runner.updated" => "runner",
    "runner.deleted" => "runner",
    "runner.claude_login_started" => "runner",
    "runner.claude_login_completed" => "runner",
    "runner.claude_login_failed" => "runner",
    "runner.codex_login_started" => "runner",
    "runner.codex_login_completed" => "runner",
    "runner.codex_login_failed" => "runner",
    "self_heal.remediation_applied" => "runner",
    "self_heal.remediation_reverted" => "runner",
    "execution_control.enabled" => "settings",
    "execution_control.disabled" => "settings",
    "agent_run.created" => "run",
    "agent_run.cancelled" => "run",
    "agent_run.execution_parked" => "run",
    "agent_run.retried" => "run",
    "agent_run.terminated" => "run",
    "agent_run.resumed" => "run",
    "run_shell.executed" => "run",
    "propose_pull_request.executed" => "run",
    "search_issues.executed" => "run",
    "prompt_version.approved" => "approval",
    "prompt_version.rejected" => "approval",
    "configuration_profile.applied" => "configuration_profile",
    "configuration_profile.reverted" => "configuration_profile",
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
    when "operations.dashboard_updated"
      "Updated enterprise operations and reliability settings"
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
    when "runner.claude_login_started"
      "Started Claude browser login for #{metadata_value('credential_name')}"
    when "runner.claude_login_completed"
      "Completed Claude browser login for #{metadata_value('credential_name')}"
    when "runner.claude_login_failed"
      "Claude browser login failed for #{metadata_value('credential_name')}"
    when "runner.codex_login_started"
      "Started Connect Codex login for #{metadata_value('credential_name')}"
    when "runner.codex_login_completed"
      "Completed Connect Codex login for #{metadata_value('credential_name')}"
    when "runner.codex_login_failed"
      "Connect Codex login failed for #{metadata_value('credential_name')}"
    when "self_heal.remediation_applied"
      "Auto-applied #{metadata_value('remediation_action').to_s.humanize.downcase} for #{metadata_value('target_label')}"
    when "self_heal.remediation_reverted"
      "Reverted #{metadata_value('remediation_action').to_s.humanize.downcase} for #{metadata_value('target_label')}"
    when "execution_control.enabled"
      "Enabled #{metadata_value('execution_control_scope')} execution disable (#{metadata_value('execution_control_mode')})"
    when "execution_control.disabled"
      "Disabled #{metadata_value('execution_control_scope')} execution disable"
    when "agent_run.created"
      "Created agent run ##{metadata_value('agent_run_id')} on #{metadata_value('project_name')}"
    when "agent_run.cancelled"
      "Cancelled agent run ##{metadata_value('agent_run_id')}"
    when "agent_run.execution_parked"
      "Parked agent run ##{metadata_value('agent_run_id')}"
    when "agent_run.retried"
      "Retried agent run ##{metadata_value('agent_run_id')} -> ##{metadata_value('new_agent_run_id')}"
    when "agent_run.terminated"
      "Terminated agent run ##{metadata_value('agent_run_id')}"
    when "agent_run.resumed"
      "Resumed agent run ##{metadata_value('agent_run_id')}"
    when "propose_pull_request.executed"
      "Proposed pull request ##{metadata_value('pull_request_number')}"
    when "search_issues.executed"
      "Searched #{metadata_value('project_name')} issues for duplicates"
    when "prompt_version.approved"
      "Approved prompt #{metadata_value('prompt_slug')} v#{metadata_value('version')}"
    when "prompt_version.rejected"
      "Rejected prompt #{metadata_value('prompt_slug')} v#{metadata_value('version')}"
    when "configuration_profile.applied"
      "Applied posture #{metadata_value('label')} to #{metadata_value('project_name')}"
    when "configuration_profile.reverted"
      "Reverted posture change on #{metadata_value('project_name')}"
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
    when "account.updated", "tenant_configuration.updated", "compliance.assurance_updated", "operations.dashboard_updated"
      Array(metadata.to_h["changed_fields"]).map { |field| "#{field.humanize} changed" }
    when "ownership.transferred"
      [ "Previous owner: #{metadata_value('from_email')}" ]
    when "project.updated", "project.settings_changed"
      Array(metadata.to_h["changed_fields"]).map { |field| "#{field.to_s.humanize} changed" }
    when "project.created"
      Array(metadata.to_h["github_url"]).compact
    when "runner.created", "runner.updated",
      "runner.claude_login_started", "runner.claude_login_completed", "runner.claude_login_failed",
      "runner.codex_login_started", "runner.codex_login_completed", "runner.codex_login_failed"
      Array(metadata.to_h["details"]).compact
    when "self_heal.remediation_applied", "self_heal.remediation_reverted"
      Array(metadata.to_h["details"]).compact
    when "execution_control.enabled", "execution_control.disabled"
      Array(metadata.to_h["reason"]).compact
    when "agent_run.created"
      Array(metadata.to_h["details"]).compact
    when "agent_run.execution_parked"
      Array(metadata.to_h["result"]).compact
    when "agent_run.retried"
      Array(metadata.to_h["details"]).compact
    when "propose_pull_request.executed"
      Array(metadata.to_h["pull_request_url"]).compact
    when "search_issues.executed"
      detail = +"Query: #{metadata_value('query')}"
      detail << " (state: #{metadata_value('state')})" if metadata.to_h["state"].present?
      [ detail ]
    when "prompt_version.approved"
      Array(metadata.to_h["notes"]).compact.map { |n| "Notes: #{n}" }
    when "prompt_version.rejected"
      Array(metadata.to_h["notes"]).compact.map { |n| "Notes: #{n}" }
    when "configuration_profile.applied", "configuration_profile.reverted"
      Array(metadata.to_h["changed_fields"]).map { |field| "#{field.to_s.humanize} changed" }
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
