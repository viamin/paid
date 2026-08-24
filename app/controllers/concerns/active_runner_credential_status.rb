# frozen_string_literal: true

# Surfaces the account's active managed runner credential on login-session
# pages so operators see existing auth before starting a redundant login.
# @spec SUBSCRIPTION-RUNNER-AUTH-004
module ActiveRunnerCredentialStatus
  extend ActiveSupport::Concern

  private

  def load_active_credential_status(runner_key)
    @active_runner_credential = active_runner_credential(runner_key)
    @credential_runner = account_runner_for(runner_key) if @active_runner_credential
  end

  def active_runner_credential(runner_key)
    policy_scope(RunnerCredential).for_runner(runner_key).active.order(created_at: :desc).first
  end

  def account_runner_for(runner_key)
    Runner.kept_only
      .joins(:user)
      .where(users: { account_id: current_account.id }, runner_key: runner_key)
      .order(:id)
      .first
  end
end
