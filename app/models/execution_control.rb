# frozen_string_literal: true

# @spec EXEC-DISABLE-001
class ExecutionControl < ApplicationRecord
  SCOPES = %w[global account project runner backend].freeze
  MODES = %w[capacity emergency].freeze
  SCOPE_PRIORITIES = {
    "global" => 5,
    "account" => 4,
    "project" => 3,
    "runner" => 2,
    "backend" => 1
  }.freeze
  PARK_MARKER_KEY = "execution_control".freeze

  belongs_to :account, optional: true
  belongs_to :project, optional: true
  belongs_to :runner, class_name: "Runner", optional: true
  belongs_to :docker_host, optional: true

  validates :scope, presence: true, inclusion: { in: SCOPES }
  validates :mode, presence: true, inclusion: { in: MODES }
  validate :target_matches_scope

  scope :enabled, -> { where(enabled: true) }
  scope :global_scope, -> { where(scope: "global") }
  scope :for_account_scope, ->(account_id) { where(scope: "account", account_id: account_id) }
  scope :for_project_scope, ->(project_id) { where(scope: "project", project_id: project_id) }
  scope :for_runner_scope, ->(runner_id) { where(scope: "runner", runner_id: runner_id) }
  scope :for_backend_scope, ->(docker_host_id) { where(scope: "backend", docker_host_id: docker_host_id) }

  def emergency?
    mode == "emergency"
  end

  def capacity?
    mode == "capacity"
  end

  def priority
    [ emergency? ? 1 : 0, SCOPE_PRIORITIES.fetch(scope) ]
  end

  def target
    case scope
    when "account" then account
    when "project" then project
    when "runner" then runner
    when "backend" then docker_host
    end
  end

  private

  def target_matches_scope
    expected = {
      "global" => [],
      "account" => [ :account_id ],
      "project" => [ :project_id ],
      "runner" => [ :runner_id ],
      "backend" => [ :docker_host_id ]
    }.fetch(scope, [])
    present = [ :account_id, :project_id, :runner_id, :docker_host_id ].select { |key| public_send(key).present? }
    return if present == expected

    errors.add(:base, "target must match scope")
  end
end
