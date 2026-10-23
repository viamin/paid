# frozen_string_literal: true

require "rails_helper"

# @spec QUESTION-EXPLORATION-013
RSpec.describe ChatInvestigations::Cancel, ".call" do
  self.use_transactional_tests = false

  let(:investigation) { create(:chat_investigation, status: "running", reserved_cost_cents: 10) }
  let!(:budget) { create(:cost_budget, :hard_stop, :daily, project: investigation.project, limit_cents: 100) }

  after do
    investigation.account.destroy!
  end

  it "waits out an in-flight Run#settle! instead of racing its budget release" do
    ready = Queue.new
    release = Queue.new

    settle_thread = start_settle_holder(investigation.id, ready, release)
    ready.pop

    cancel_thread = start_cancel(investigation.id, investigation.created_by_id)
    expect(cancel_thread.join(2)).to be_nil # blocked on the project row lock settle is holding

    release << true
    raise "Settle timed out" unless settle_thread.join(10)
    raise "Cancel timed out" unless cancel_thread.join(10)

    expect(investigation.reload).to have_attributes(status: "completed", reserved_cost_cents: 0, cancelled_at: nil)
    expect(budget.reload.current_usage_cents).to eq(10)
  ensure
    release << true
    [ settle_thread, cancel_thread ].compact.each { |thread| thread.kill.join if thread.alive? }
  end

  private

  # Simulates Run#settle! holding the project row lock mid-execution, the exact
  # window cancel.rb's project lock (added alongside this test) must wait out.
  def start_settle_holder(investigation_id, ready, release)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          locked_investigation = ChatInvestigation.find(investigation_id)
          locked_investigation.project.with_lock do
            ready << true
            release.pop
            ChatInvestigations::Run.new(investigation: locked_investigation).send(:settle!, status: "completed", result: "done")
          end
        end
      end
    end
  end

  def start_cancel(investigation_id, actor_id)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          ChatInvestigations::Cancel.call(investigation: ChatInvestigation.find(investigation_id), actor: User.find(actor_id))
        end
      end
    end
  end
end
