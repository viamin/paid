# frozen_string_literal: true

require "rails_helper"

RSpec.describe Strategy, :tenant_isolation do
  self.use_transactional_tests = false

  [ :current, :parent ].each do |reference|
    # @spec POSTGRESQL-PERSISTENCE-013
    it "keeps a #{reference} binding valid during concurrent version reassignment" do
      account = TenantContext.with_system_access { create(:account) }
      worker = nil
      TenantContext.with(account) do
        own, other, version, child = strategy_records(account)
        ActiveRecord::Base.transaction do
          bind_reference(reference, own, version, child)
          worker, pid = reassign_version(account, version.id, other.id)
          wait_for_reference_lock(pid)
        end
        expect_reassignment_rejected(worker, version, own)
        bound_id = reference == :current ? own.reload.current_version_id : child.reload.parent_version_id
        expect(bound_id).to eq(version.id)
      end
    ensure
      worker&.kill&.join if worker&.alive?
      TenantContext.with_system_access { account&.destroy! }
    end
  end

  def strategy_records(account)
    own = create(:strategy, account:)
    other = create(:strategy, account:)
    [ own, other, create(:strategy_version, strategy: own), create(:strategy_version, strategy: own) ]
  end

  def bind_reference(reference, own, version, child)
    if reference == :current
      own.update_columns(current_version_id: version.id)
    else
      child.update_columns(parent_version_id: version.id)
    end
  end

  def reassign_version(account, version_id, other_id)
    started = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        TenantContext.with(account) do
          connection.transaction do
            connection.execute("SET LOCAL lock_timeout = '5s'")
            started << connection.select_value("SELECT pg_backend_pid()")
            connection.execute("UPDATE strategy_versions SET strategy_id = #{Integer(other_id)} WHERE id = #{Integer(version_id)}")
          end
        end
      end
    rescue ActiveRecord::StatementInvalid => error
      error
    end
    pid = started.pop(timeout: 5)
    raise "Version reassignment did not start" unless pid

    [ worker, pid ]
  rescue StandardError
    worker&.kill&.join
    raise
  end

  def wait_for_reference_lock(pid)
    connection = ActiveRecord::Base.connection
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    until connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
      raise "Version reassignment did not wait for reference lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def expect_reassignment_rejected(worker, version, own)
    raise "Version reassignment timed out" unless worker.join(10)

    expect(worker.value).to be_a(ActiveRecord::StatementInvalid)
    expect(worker.value.message).to include("strategy_id cannot change")
    expect(version.reload.strategy_id).to eq(own.id)
  end
end
