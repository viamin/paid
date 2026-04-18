# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityAlerts::CheckGate do
  let(:account) { create(:account) }
  let(:project) do
    create(:project, account: account, quality_gate_settings: {
      "enabled" => true,
      "composite_score_threshold" => 0.5,
      "min_recent_runs" => 3,
      "lookback_window_hours" => 24
    })
  end

  before do
    allow(Turbo::StreamsChannel).to receive(:broadcast_replace_to)
  end

  describe ".call" do
    context "when quality gates are breached" do
      before do
        3.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.3,
            scores: { "pr_created" => 0.0, "ci_passed" => 0.0 })
        end
      end

      it "publishes a notification" do
        expect {
          described_class.call(project: project)
        }.to change(Notification, :count).by(1)
      end

      it "creates a warning-level notification" do
        described_class.call(project: project)

        notification = Notification.last
        expect(notification.source).to eq("quality_gate_breach")
        expect(notification.severity).to eq("warning")
        expect(notification.subject).to eq(project)
        expect(notification.title).to include(project.name)
        expect(notification.action_url).to eq("/projects/#{project.id}/quality_dashboard")
        expect(notification.nav_section).to eq("projects")
      end

      it "includes breach details in metadata" do
        described_class.call(project: project)

        metadata = Notification.last.metadata
        expect(metadata["breaches"]).to be_present
        expect(metadata["recent_runs"]).to be_present
        expect(metadata["remediation_actions"]).to be_present
        expect(metadata["sample_size"]).to eq(3)
      end

      it "updates existing notification on subsequent breaches" do
        described_class.call(project: project)

        agent_run = create(:agent_run, project: project)
        create(:quality_metric, agent_run: agent_run, composite_score: 0.2)

        expect {
          described_class.call(project: project)
        }.not_to change(Notification, :count)
      end

      it "creates an error-level notification for severe composite score drop" do
        # Score is less than 50% of threshold (0.5 * 0.5 = 0.25)
        QualityMetric.update_all(composite_score: 0.1)

        described_class.call(project: project)

        expect(Notification.last.severity).to eq("error")
      end
    end

    context "when quality gates are not breached" do
      before do
        3.times do
          agent_run = create(:agent_run, project: project)
          create(:quality_metric, agent_run: agent_run, composite_score: 0.9,
            scores: { "pr_created" => 1.0, "ci_passed" => 1.0 })
        end
      end

      it "does not create a notification" do
        expect {
          described_class.call(project: project)
        }.not_to change(Notification, :count)
      end

      it "resolves an existing breach notification" do
        notification = Notifications::Publish.call(
          account: account,
          source: "quality_gate_breach",
          subject: project,
          severity: :warning,
          title: "Quality gate triggered"
        )

        described_class.call(project: project)

        expect(notification.reload.resolved_at).to be_present
      end
    end

    context "when quality gates are disabled" do
      before { project.update!(quality_gate_settings: { "enabled" => false }) }

      it "does not create a notification" do
        expect {
          described_class.call(project: project)
        }.not_to change(Notification, :count)
      end
    end
  end
end
