# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  describe ".call" do
    # @spec QUEUE-DIAGNOSIS-001
    it "identifies eligible work which has not reached the scheduler" do
      create(:issue, project:, github_state: "open", paid_state: "new")

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:runnable_work_not_seeded)
      expect(diagnosis.eligible_count).to eq(1)
      expect(diagnosis.queued_count).to eq(0)
      expect(diagnosis.next_action).to include("eligibility sweep")
    end

    # @spec QUEUE-DIAGNOSIS-002
    it "does not call an empty queue stalled while all visible work is active" do
      issue = create(:issue, project:, github_state: "open", paid_state: "in_progress")
      create(:agent_run, :running, project:, issue: issue)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:healthy_active_work)
      expect(diagnosis.active_count).to eq(1)
    end

    # @spec QUEUE-DIAGNOSIS-003
    it "reports a dependency hold without claiming that the queue is broken" do
      blocker = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
      create(:issue, project:, github_state: "open", paid_state: "new") do |dependent|
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
      end

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:genuine_holds)
      expect(diagnosis.excluded_count).to eq(2)
      expect(diagnosis.next_action).to include("Inbox")
    end

    # @spec QUEUE-DIAGNOSIS-004
    it "identifies an intentional scheduler pause" do
      project.update!(scheduler_paused_at: Time.current)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:resource_or_policy_paused)
      expect(diagnosis.next_action).to include("Resume")
    end

    # @spec QUEUE-DIAGNOSIS-005
    it "reports unavailable coverage when canonical eligibility cannot be read" do
      allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:unknown)
      expect(diagnosis.error_class).to eq("ActiveRecord::ConnectionNotEstablished")
      expect(diagnosis.next_action).to include("Refresh")
    end
  end
end
