# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::QueueDiagnosis do
  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  describe ".call" do
    # @spec AUTO-PICK-QUEUE-014
    it "identifies eligible work that has not been seeded" do
      create(:issue, project:, github_state: "open", paid_state: "new")

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:runnable_unseeded)
      expect(diagnosis.eligible_count).to eq(1)
      expect(diagnosis.queued_count).to eq(0)
      expect(diagnosis.active_count).to eq(0)
    end

    # @spec AUTO-PICK-QUEUE-014
    it "does not call active work an empty backlog" do
      issue = create(:issue, project:, github_state: "open", paid_state: "new")
      create(:agent_run, project:, issue:, status: "running", started_at: Time.current)

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:active_work)
      expect(diagnosis.eligible_count).to eq(0)
      expect(diagnosis.active_count).to eq(1)
    end

    # @spec AUTO-PICK-QUEUE-014
    it "reports backend queued work when the rendered preview is empty" do
      create(:agent_run, :queued, project: project)

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:backend_queued)
      expect(diagnosis.queued_count).to eq(1)
    end

    # @spec AUTO-PICK-QUEUE-014
    it "identifies ordinary admission holds without claiming a failure" do
      create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "skip" ])
      project.update!(auto_pick_skip_labels: [ "skip" ])

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:held)
      expect(diagnosis.open_count).to eq(1)
      expect(diagnosis.eligible_count).to eq(0)
    end

    # @spec AUTO-PICK-QUEUE-014
    it "reports a deliberate project pause separately" do
      project.update!(quality_paused_at: Time.current)

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:paused)
    end

    # @spec AUTO-PICK-QUEUE-014
    it "reports an account scheduler pause separately" do
      account.update!(scheduler_paused_at: Time.current)

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:paused)
    end

    # @spec AUTO-PICK-QUEUE-014
    it "returns unknown coverage when the eligibility query is unavailable" do
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to receive(:eligible_scope).and_raise(ActiveRecord::StatementInvalid, "unavailable")

      diagnosis = described_class.call(user:)

      expect(diagnosis.status).to eq(:unknown)
      expect(diagnosis.error).to include("unavailable")
    end

    # @spec AUTO-PICK-QUEUE-014
    it "does not include another tenant's queued or eligible work" do
      other_project = create(:project, auto_pick_enabled: true, active: true)
      create(:issue, project: other_project, github_state: "open", paid_state: "new")
      create(:agent_run, :queued, project: other_project)

      diagnosis = described_class.call(user:)

      expect(diagnosis.project_ids).to eq([ project.id ])
      expect(diagnosis.open_count).to eq(0)
      expect(diagnosis.queued_count).to eq(0)
    end
  end
end
