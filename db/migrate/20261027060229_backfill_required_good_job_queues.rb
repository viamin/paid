# frozen_string_literal: true

# A tenant may have persisted its own `good_job_queues` allocation before the
# reviewer evaluation lifecycle introduced the `shadow_evaluation` queue. That
# persisted override wins over the deployment environment, so the required
# queue has to be added back to the stored allocation; otherwise the reviewer
# evaluations stay queued with no worker to run them. The stored thread
# allocation is reconciled against the tenant's own thread budget so the
# persisted configuration stays consistent.
#
# @spec INTENT-CONFORMANCE-ROLLOUT-011
class BackfillRequiredGoodJobQueues < ActiveRecord::Migration[8.1]
  class MigrationTenantSetting < ApplicationRecord
    self.table_name = "tenant_settings"
  end

  DEFAULT_MAX_THREADS = 12

  def up
    # tenant_settings carries forced tenant RLS, so a migration running without
    # a tenant context matches zero rows and silently no-ops.
    TenantContext.with_system_access do
      MigrationTenantSetting.find_each do |setting|
        settings = setting.worker_settings || {}
        queues = settings["good_job_queues"]
        next unless queues.is_a?(String)

        reconciled = WorkerSettings::GoodJobQueues.reconcile(queues, max_threads: max_threads(settings))
        next if reconciled == queues

        setting.update!(worker_settings: settings.merge("good_job_queues" => reconciled))
      end
    end
  end

  def down
    # Not reversible: a stored allocation that already served the required
    # queue is indistinguishable from one this migration added, and removing it
    # would drop a queue the platform requires.
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # The tenant's own thread budget when it stored one, otherwise the platform
  # default the tenant setting falls back to.
  def max_threads(settings)
    configured = Integer(settings["good_job_max_threads"].to_s, exception: false)
    return configured if configured&.positive?

    DEFAULT_MAX_THREADS
  end
end
