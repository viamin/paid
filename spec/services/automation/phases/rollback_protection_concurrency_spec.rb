# frozen_string_literal: true

require "rails_helper"

# Concurrent grant creation must serialize with a guarded rollout rollback:
# a grant created while the rollback is checking can never leave the phase
# model silently reverted under legacy interpretation.
#
# @spec AUTOMATION-PHASES-014
RSpec.describe Automation::Phases::RollbackProtection do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:project) { create(:project, account:, auto_pick_enabled: true) }

  before do
    FeatureFlags.flipper.features.each(&:remove)
    FeatureFlags.enable!(:automation_phases, project:)
  end

  after do
    FeatureFlags.flipper.features.each(&:remove)
    WorkItemContinuationGrant.where(project_id: project.id).destroy_all
    account.destroy!
  end

  describe "grant creation concurrent with a guarded rollback" do
    it "refuses the rollback when a grant is created while it waits on the lock" do
      issue = create(:issue, project:, github_state: "open")
      grant_thread = create_grant_under_lock(issue)
      disable_result = Queue.new
      disable_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          FeatureFlags.disable!(:automation_phases, project: Project.find(project.id))
          disable_result << :permitted
        rescue FeatureFlags::RollbackBlockedError => error
          disable_result << error
        end
      end

      wait_for_disable_to_block_on_lock
      release_queue << true

      expect(disable_result.pop).to be_a(FeatureFlags::RollbackBlockedError)

      expect(FeatureFlags.enabled?(:automation_phases, project: Project.find(project.id))).to be(true)
      expect(WorkItemContinuationGrant.active.where(project_id: project.id).exists?).to be(true)
    ensure
      [ grant_thread, disable_thread ].compact.each { |thread| thread.kill.join if thread.alive? }
    end
  end

  private

  def release_queue
    @release_queue ||= Queue.new
  end

  # Holds the shared per-project advisory lock, creates the grant inside it,
  # then parks until the guarded disable has had its turn to wait.
  def create_grant_under_lock(issue)
    ready = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.with_project_lock(Project.find(project.id)) do
          create(:work_item_continuation_grant, project: Project.find(project.id),
            issue: Issue.find(issue.id), start_phase: "coding", endpoint: "merge")
          ready << true
          release_queue.pop
        end
      end
    end
    ready.pop
    thread
  end

  def wait_for_disable_to_block_on_lock
    Timeout.timeout(5) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT EXISTS (
            SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND NOT granted
          )
        SQL
        return if ActiveModel::Type::Boolean.new.cast(waiting)

        Thread.pass
      end
    end
  end
end
