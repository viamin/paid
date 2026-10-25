# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-PICK-QUEUE-017
RSpec.describe Dashboard::QueueDiagnosis do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user, auto_pick_enabled: true, active: true) }

  describe ".call" do
    it "separates active work from an empty waiting backlog" do
      create(:agent_run, :running, project:, started_at: 1.minute.ago)

      result = described_class.call(user:)

      expect(result).to have_attributes(state: :active_work, eligible_count: 0, queued_count: 0, active_count: 1)
    end

    it "identifies eligible work that was not seeded" do
      create(:issue, project:, github_state: "open", paid_state: "new")

      result = described_class.call(user:)

      expect(result).to have_attributes(state: :runnable_unseeded, eligible_count: 1, queued_count: 0, active_count: 0)
      expect(result.next_action).to include("seed")
    end

    it "reports deliberate dependency holds with the Inbox recovery path" do
      blocker = create(:issue, project:, github_state: "open", paid_state: "new", labels: [ "tracking" ])
      create(:issue, project:, github_state: "open", paid_state: "new") do |dependent|
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
      end

      result = described_class.call(user:)

      expect(result).to have_attributes(state: :held, eligible_count: 0, queued_count: 0)
      expect(result.blockers).to include(hash_including(kind: :dependency, count: 1, action: "Open Inbox"))
    end

    it "reports a quality pause as policy rather than a scheduler failure" do
      project.update!(quality_paused_at: Time.current)

      result = described_class.call(user:)

      expect(result).to have_attributes(state: :policy_paused, queued_count: 0)
      expect(result.next_action).to include("Resume")
    end

    it "returns unknown coverage when eligibility data is unavailable" do
      allow(Dashboard::EligibilityBreakdown).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished)

      result = described_class.call(user:)

      expect(result).to have_attributes(state: :unknown, covered?: false)
      expect(result.next_action).to include("Refresh")
    end

    it "does not include another tenant's queued or active work" do
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_project = create(:project, account: other_account, created_by: other_user, auto_pick_enabled: true)
      create(:agent_run, :queued, project: other_project)
      create(:agent_run, :running, project: other_project)

      result = described_class.call(user:)

      expect(result).to have_attributes(queued_count: 0, active_count: 0)
    end

    it "refreshes its cached coverage when queue membership changes" do
      first = described_class.call(user:)
      create(:agent_run, :queued, project:)
      refreshed = described_class.call(user:)

      expect(first.queued_count).to eq(0)
      expect(refreshed.queued_count).to eq(1)
    end
  end
end
