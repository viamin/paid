# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::Reconcile do
  self.use_transactional_tests = false

  let(:project) { create(:project) }
  let(:parent) { create(:issue, :in_progress, project:, github_state: "open") }
  let(:run) { create(:agent_run, :completed, project:, issue: parent, pull_request_number: 99) }
  let(:actor) { create(:user, account: project.account) }
  let(:gap) do
    { "criterion" => "macOS acceptance", "kind" => "human", "next_step" => "Run the pilot." }
  end

  after do
    project.account.destroy!
  end

  it "does not discard evidence submitted while reconciliation waits to publish" do # @spec PARTIAL-CLOSEOUT-033
    publishing = Queue.new
    release = Queue.new
    delay_reconciliation_publish(publishing, release)
    described_class.call(agent_run: run, assessment: { "gaps" => [ gap ] })
    notification = Notification.find_by!(subject: parent, source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE)
    occurrence = notification.metadata.fetch("prerequisites").sole

    reconciliation_thread = reconcile(run.id)
    publishing.pop
    submission_thread = submit_evidence(notification.id, occurrence.fetch("identity"))
    submission_thread.join(2)

    release << true
    wait_for_threads(submission_thread, reconciliation_thread)

    expect(notification.reload.metadata.fetch("evidence_submissions").sole).to include(
      "evidence_url" => "https://evidence.example.test/report",
      "explanation" => "Pilot report attached."
    )
  ensure
    release << true
    [ submission_thread, reconciliation_thread ].compact.each { |thread| thread.kill.join if thread.alive? }
  end

  private

  def delay_reconciliation_publish(publishing, release)
    allow(Notifications::Publish).to receive(:call).and_wrap_original do |original, **arguments|
      if Thread.current[:delay_prerequisite_publish]
        publishing << true
        release.pop
      end
      original.call(**arguments)
    end
  end

  def wait_for_threads(*threads)
    threads.each do |thread|
      raise "Concurrent prerequisite update timed out" unless thread.join(10)

      thread.value
    end
  end

  def submit_evidence(notification_id, prerequisite_identity)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          PartialCloseouts::SubmitEvidence.call(
            notification: Notification.find(notification_id), actor: User.find(actor.id), prerequisite_identity:,
            evidence_url: "https://evidence.example.test/report", explanation: "Pilot report attached."
          )
        end
      end
    end
  end

  def reconcile(run_id)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TenantContext.with_system_access do
          Thread.current[:delay_prerequisite_publish] = true
          described_class.call(agent_run: AgentRun.find(run_id), assessment: { "gaps" => [ gap ] })
        ensure
          Thread.current[:delay_prerequisite_publish] = nil
        end
      end
    end
  end
end
