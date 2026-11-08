# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDelegation::SelectPosture do
  self.use_transactional_tests = false

  # @spec PROJECT-DELEGATION-001
  it "serializes concurrent first selections into successive revisions and audit events" do
    account = create(:account)
    owner = create(:user, :owner, account:)
    project = create(:project, :with_github_installation, account:, created_by: owner)
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)

    results = concurrently_select(project:, actor: owner)

    expect(results.map(&:revision).sort).to eq([ 1, 2 ])
    expect(ProjectDelegationPosture.where(project:).sole.revision).to eq(2)
    expect(audit_events(project).order(:id).map { |event| event.metadata.fetch("revision") }).to eq([ 1, 2 ])
  ensure
    account&.destroy!
  end

  private

  def concurrently_select(project:, actor:)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map { selection_thread(project.id, actor.id, ready, start) }
    2.times { ready.pop }
    2.times { start << true }
    threads.map do |thread|
      raise "Concurrent posture selection timed out" unless thread.join(10)

      thread.value
    end
  ensure
    threads&.each { |thread| thread.kill.join if thread.alive? }
  end

  def selection_thread(project_id, actor_id, ready, start)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          project = Project.find(project_id)
          actor = User.find(actor_id)
          ready << true
          start.pop
          described_class.call(project:, actor:, level: "bounded_delivery")
        end
      end
    end
  end

  def audit_events(project)
    AccountActivityEvent.where(action: "project_delegation.posture_selected", subject: project)
  end
end
