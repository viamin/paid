# frozen_string_literal: true

module Runners
  # Scheduled job that proactively refreshes upstream quota snapshots for all
  # users. Runs every 15 minutes so the /runners page shows reasonably fresh
  # quota data without requiring auto-weight to be enabled. Weight adjustment
  # is a separate concern handled by RunnerQuotaBalanceJob (auto-weight users
  # only).
  #
  # The query filters on subscription runners as a proxy for "users who have
  # any runners that need quota refresh". This works because
  # Runner.ensure_default_for guarantees every user receives a default
  # subscription runner; the subscription filter therefore matches every active
  # user. RefreshQuotaSnapshots#call then refreshes all kept/enabled runners
  # for each user, regardless of auth_type.
  class RefreshQuotaSnapshotsJob < ApplicationJob
    include GoodJob::ActiveJobExtensions::Concurrency

    queue_as :maintenance

    good_job_control_concurrency_with(
      total_limit: 1,
      enqueue_limit: 1,
      key: -> { "runners_refresh_quota_snapshots" }
    )

    def perform
      User.joins(:runners)
        .merge(Runner.kept_only.subscription)
        .distinct
        .find_each do |user|
          Runners::RefreshQuotaSnapshots.call(user: user)
        end
    end
  end
end
