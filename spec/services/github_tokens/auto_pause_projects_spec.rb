# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubTokens::AutoPauseProjects do
  let(:account) { create(:account) }
  let(:github_token) do
    create(:github_token, :validation_failed, account: account,
      validation_error: "Token is invalid or has been revoked: Bad credentials")
  end

  before do
    allow(ProjectWorkflowManager).to receive(:stop_polling)
  end

  describe ".call" do
    context "with active projects using the failed token" do
      let!(:project) { create(:project, account: account, github_token: github_token) }

      it "pauses the project" do
        described_class.call(github_token: github_token)

        expect(project.reload.scheduler_paused_at).to be_present
      end

      it "stops the project's poll workflow so it doesn't keep hitting the dead credential" do
        described_class.call(github_token: github_token)

        expect(ProjectWorkflowManager).to have_received(:stop_polling).with(project)
      end

      it "still pauses the project even if stopping the poll workflow errors" do
        allow(ProjectWorkflowManager).to receive(:stop_polling).and_raise(StandardError, "boom")
        allow(Rails.logger).to receive(:error)

        described_class.call(github_token: github_token)

        expect(project.reload.scheduler_paused_at).to be_present
        expect(Rails.logger).to have_received(:error).with(
          hash_including(message: "github_token.auto_pause.stop_polling_failed", project_id: project.id)
        )
      end

      it "sets the pause reason" do
        described_class.call(github_token: github_token)

        expect(project.reload.scheduler_pause_reason).to include("failed validation")
        expect(project.reload.scheduler_pause_reason).to include(github_token.name)
      end

      it "returns paused project ids" do
        result = described_class.call(github_token: github_token)

        expect(result).to eq([ project.id ])
      end

      it "logs the auto-pause event" do
        allow(Rails.logger).to receive(:info)

        described_class.call(github_token: github_token)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "github_token.auto_pause",
            github_token_id: github_token.id,
            project_ids: [ project.id ]
          )
        )
      end
    end

    context "with already-paused projects" do
      let!(:project) do
        create(:project, account: account, github_token: github_token,
          scheduler_paused_at: 1.hour.ago,
          scheduler_pause_reason: "GitHub token '#{github_token.name}' failed validation: Bad credentials")
      end

      it "does not double-pause" do
        result = described_class.call(github_token: github_token)

        expect(result).to be_empty
        expect(project.reload.scheduler_pause_reason).to include("failed validation")
      end

      it "still stops polling for previously auto-paused projects, even though it doesn't re-pause" do
        # stop_polling is retried on every call regardless of prior pause
        # state for auto-paused projects, so a project paused before this
        # behavior existed (or one whose poll workflow was independently
        # restarted) still converges to stopped once the token is confirmed
        # dead.
        described_class.call(github_token: github_token)

        expect(ProjectWorkflowManager).to have_received(:stop_polling).with(project)
      end
    end

    context "with manually paused projects" do
      let!(:project) do
        create(:project, account: account, github_token: github_token,
          scheduler_paused_at: 1.hour.ago, scheduler_pause_reason: "manually paused")
      end

      it "does not stop polling because auto-resume will not restart it" do
        described_class.call(github_token: github_token)

        expect(project.reload.scheduler_pause_reason).to eq("manually paused")
        expect(ProjectWorkflowManager).not_to have_received(:stop_polling)
      end
    end

    context "with inactive projects" do
      let!(:project) { create(:project, :inactive, account: account, github_token: github_token) }

      it "does not pause inactive projects" do
        result = described_class.call(github_token: github_token)

        expect(result).to be_empty
        expect(project.reload.scheduler_paused_at).to be_nil
      end

      it "does not stop polling" do
        described_class.call(github_token: github_token)

        expect(ProjectWorkflowManager).not_to have_received(:stop_polling)
      end
    end

    context "with no projects using the token" do
      it "returns empty array" do
        result = described_class.call(github_token: github_token)

        expect(result).to be_empty
      end
    end

    context "with mixed projects across different tokens" do
      let(:other_token) { create(:github_token, account: account) }
      let!(:affected_project) { create(:project, account: account, github_token: github_token) }
      let!(:unaffected_project) { create(:project, account: account, github_token: other_token) }

      it "only pauses projects using the failed token" do
        described_class.call(github_token: github_token)

        expect(affected_project.reload.scheduler_paused_at).to be_present
        expect(unaffected_project.reload.scheduler_paused_at).to be_nil
      end
    end
  end
end
