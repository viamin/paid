# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ReenqueueEligibleJob do
  describe "#perform" do
    it "rechecks an eligible issue" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).to have_received(:call).with(issue, project: project, skip_project_gate: true)
    end

    it "does nothing for missing issues" do
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(-1)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "does nothing for pull requests" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, :pull_request, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "does nothing for intentional waiting states" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "needs_input", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "does nothing when the auto-pick project gate defers work" do
      project = create(:project, auto_pick_enabled: true, quality_paused_at: Time.current)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call)

      described_class.perform_now(issue.id)

      expect(Issues::EnqueueEligible).not_to have_received(:call)
    end

    it "logs and swallows enqueue errors" do
      project = create(:project, auto_pick_enabled: true)
      issue = create(:issue, project: project, paid_state: "failed", github_state: "open")
      allow(Issues::EnqueueEligible).to receive(:call).and_raise(StandardError, "transient failure")
      allow(Rails.logger).to receive(:error)

      expect { described_class.perform_now(issue.id) }.not_to raise_error
      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "enqueue_eligible.issue_state_change_failed",
          issue_id: issue.id,
          error: "transient failure"
        )
      )
    end
  end
end
