# frozen_string_literal: true

class RunnerQuotaBalanceJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: -> { "runner_quota_balance_#{arguments.first || "all"}" }
  )

  def perform(user_id = nil)
    scoped_settings(user_id).find_each do |setting|
      Runners::QuotaBalanceService.call(user: setting.user)
    end
  end

  private

  def scoped_settings(user_id)
    scope = UserSetting.includes(:user).where(auto_weight_enabled: true)
    return scope unless user_id

    scope.where(user_id: user_id)
  end
end
