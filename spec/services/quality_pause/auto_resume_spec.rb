# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityPause::AutoResume do
  describe ".call" do
    let(:project) { create(:project, quality_paused_at: 1.hour.ago) }

    before do
      allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
    end

    it "resumes a paused project and records an audit event" do
      result = described_class.call(
        project: project,
        reason: "prompt_evolution_variant_created",
        metadata: { prompt_id: 123 }
      )

      expect(result).to be_resumed
      expect(project.reload).not_to be_quality_paused

      event = project.quality_pause_events.resumes.last
      expect(event.metadata).to include(
        "auto_resumed" => true,
        "reason" => "prompt_evolution_variant_created",
        "prompt_id" => 123
      )
    end

    it "does nothing when the project is not paused" do
      project.update!(quality_paused_at: nil)

      expect {
        described_class.call(project: project, reason: "model_change")
      }.not_to change(QualityPauseEvent, :count)
    end

    it "does not count manual resumes toward the cooldown" do
      create(:quality_pause_event, :resumed, project: project, metadata: { "manual" => true }, created_at: 1.hour.ago)

      result = described_class.call(project: project, reason: "model_change")

      expect(result).to be_resumed
      expect(project.reload).not_to be_quality_paused
    end

    it "does not count auto-resumes outside the cooldown window" do
      create_auto_resume(created_at: 25.hours.ago)
      create_auto_resume(created_at: 23.hours.ago)
      create_auto_resume(created_at: 22.hours.ago)

      result = described_class.call(project: project, reason: "model_change")

      expect(result).to be_resumed
    end

    it "leaves the project paused and publishes an alert when cooldown is exceeded" do
      create_auto_resume(created_at: 3.hours.ago)
      create_auto_resume(created_at: 2.hours.ago)
      create_auto_resume(created_at: 1.hour.ago)

      result = described_class.call(project: project, reason: "model_change")

      expect(result).to be_cooldown_limited
      expect(project.reload).to be_quality_paused

      notification = Notification.find_by(account: project.account, source: "quality_auto_resume_cooldown")
      expect(notification).to be_present
      expect(notification.severity).to eq("error")
      expect(notification.subject).to eq(project)
      expect(notification.metadata).to include(
        "reason" => "model_change",
        "max_auto_resumes" => 3
      )
    end

    def create_auto_resume(created_at:)
      create(:quality_pause_event, :resumed,
        project: project,
        metadata: { "auto_resumed" => true },
        created_at: created_at)
    end
  end
end
