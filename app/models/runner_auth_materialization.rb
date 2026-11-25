# frozen_string_literal: true

# Immutable, trusted evidence that a particular run container received a
# particular managed credential generation. It is deliberately separate from
# telemetry: a later account selection must not rewrite this authorization.
class RunnerAuthMaterialization < ApplicationRecord
  belongs_to :account
  belongs_to :project
  belongs_to :agent_run
  belongs_to :runner_credential, optional: true

  validates :runner_key, :auth_source, :container_id, :materialized_at, presence: true
  validates :auth_source, inclusion: { in: [ "managed", "host_forwarded", "api_key_proxy", "none" ] }
  validates :runner_credential, presence: true, if: -> { auth_source == "managed" }
  validates :credential_updated_at, presence: true, if: -> { auth_source == "managed" }
  validate :project_matches_agent_run
  validate :account_matches_project

  private

  def project_matches_agent_run
    return unless project && agent_run

    errors.add(:project, "must match the agent run's project") if project_id != agent_run.project_id
  end

  def account_matches_project
    return unless account && project

    errors.add(:account, "must match the project's account") if account_id != project.account_id
  end
end
