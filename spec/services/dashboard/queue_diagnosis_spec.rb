# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true) }

  describe ".call" do
    # @spec QUEUE-DIAGNOSIS-001
    it "reports eligible work that was not seeded without confusing it with queued work" do
      create(:issue, project:, github_state: "open", paid_state: "new")

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:runnable_unseeded)
      expect(diagnosis.eligible_count).to eq(1)
      expect(diagnosis.queued_count).to eq(0)
      expect(diagnosis.active_count).to eq(0)
      expect(diagnosis.next_action).to include("eligibility sweep")
    end

    # @spec QUEUE-DIAGNOSIS-002
    it "reports active work with no waiting backlog as healthy" do
      create(:agent_run, :running, project:)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:healthy_active)
      expect(diagnosis.active_count).to eq(1)
      expect(diagnosis.queued_count).to eq(0)
    end

    # @spec QUEUE-DIAGNOSIS-003
    it "reports dependency provenance instead of calling held work unseeded" do
      blocker = create(:issue, project:, github_state: "open", paid_state: "new")
      dependent = create(:issue, project:, github_state: "open", paid_state: "new")
      create(:issue_dependency, issue: dependent, depends_on_issue: blocker)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:held)
      expect(diagnosis.blockers).to include(
        have_attributes(issue: dependent, kind: :dependency, owner: blocker)
      )
    end

    # @spec QUEUE-DIAGNOSIS-004
    it "reports a deliberate scheduler pause" do
      project.update!(scheduler_paused_at: Time.current)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:paused)
      expect(diagnosis.next_action).to include("Resume")
    end

    # @spec QUEUE-DIAGNOSIS-004
    it "treats an unavailable diagnostic query as unknown coverage" do
      create(:issue, project:, github_state: "open", paid_state: "new")
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:eligible_scope).and_raise(ActiveRecord::ConnectionNotEstablished)

      diagnosis = described_class.call(user:)

      expect(diagnosis.state).to eq(:unknown)
      expect(diagnosis.next_action).to include("Refresh")
    end

    it "does not include another account's work" do
      other_project = create(:project, auto_pick_enabled: true)
      create(:issue, project: other_project, github_state: "open", paid_state: "new")

      diagnosis = described_class.call(user:)

      expect(diagnosis.eligible_count).to eq(0)
      expect(diagnosis.state).to eq(:empty)
    end
  end
end
