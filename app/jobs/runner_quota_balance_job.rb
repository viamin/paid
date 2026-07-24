# frozen_string_literal: true

class RunnerQuotaBalanceJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  queue_as :maintenance

  good_job_control_concurrency_with(
    total_limit: 1,
    enqueue_limit: 1,
    key: "runner_quota_balance"
  )

  def perform
    UserSetting.includes(:user).where(auto_weight_enabled: true).find_each do |setting|
      Runners::QuotaBalanceService.call(user: setting.user)
    end
  end
end
