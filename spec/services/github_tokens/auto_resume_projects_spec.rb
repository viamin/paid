# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubTokens::AutoResumeProjects do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }

  before do
    allow(ProjectWorkflowManager).to receive(:start_polling)
  end

  describe ".call" do
    context "with active projects auto-paused by the token" do
      let!(:project) do
        create(:project, account: account, github_token: github_token,
          scheduler_paused_at: 1.hour.ago,
          scheduler_pause_reason: "GitHub token '#{github_token.name}' failed validation: Bad credentials")
      end

      it "resumes the project" do
        described_class.call(github_token: github_token)

        expect(project.reload.scheduler_paused_at).to be_nil
        expect(project.reload.scheduler_pause_reason).to be_nil
      end

      it "restarts the project's poll workflow" do
        described_class.call(github_token: github_token)

        expect(ProjectWorkflowManager).to have_received(:start_polling)
          .with(project, restart_reason: "github_token_restored")
      end

      it "leaves the project paused if restarting the poll workflow errors" do
        allow(ProjectWorkflowManager).to receive(:start_polling).and_raise(StandardError, "boom")
        allow(Rails.logger).to receive(:error)

        result = described_class.call(github_token: github_token)

        expect(result).to be_empty
        expect(project.reload.scheduler_paused_at).to be_present
        expect(project.scheduler_pause_reason).to include("failed validation")
        expect(Rails.logger).to have_received(:error).with(
          hash_including(message: "github_token.auto_resume.start_polling_failed", project_id: project.id)
        )
      end

      it "returns resumed project ids" do
        result = described_class.call(github_token: github_token)

        expect(result).to eq([ project.id ])
      end

      it "logs the auto-resume event" do
        allow(Rails.logger).to receive(:info)

        described_class.call(github_token: github_token)

        expect(Rails.logger).to have_received(:info).with(
          hash_including(
            message: "github_token.auto_resume",
            github_token_id: github_token.id,
            project_ids: [ project.id ]
          )
        )
      end
    end

    context "with projects paused for another reason" do
      let!(:project) do
        create(:project, account: account, github_token: github_token,
          scheduler_paused_at: 1.hour.ago, scheduler_pause_reason: "manually paused")
      end

      it "does not resume the project" do
        result = described_class.call(github_token: github_token)

        expect(result).to be_empty
        expect(project.reload.scheduler_paused_at).to be_present
        expect(project.reload.scheduler_pause_reason).to eq("manually paused")
      end

      it "does not restart polling" do
        described_class.call(github_token: github_token)

        # Project creation itself triggers an unrelated start_polling(project) call;
        # assert specifically that AutoResumeProjects' own restart call never fires.
        expect(ProjectWorkflowManager).not_to have_received(:start_polling)
          .with(project, restart_reason: "github_token_restored")
      end
    end

    context "with inactive projects" do
      let!(:project) do
        create(:project, :inactive, account: account, github_token: github_token,
          scheduler_paused_at: 1.hour.ago,
          scheduler_pause_reason: "GitHub token '#{github_token.name}' failed validation: Bad credentials")
      end

      it "resumes inactive projects so they are not stuck when reactivated" do
        result = described_class.call(github_token: github_token)

        expect(result).to eq([ project.id ])
        expect(project.reload.scheduler_paused_at).to be_nil
      end

      it "does not restart polling until the project is reactivated" do
        described_class.call(github_token: github_token)

        expect(ProjectWorkflowManager).not_to have_received(:start_polling)
          .with(project, restart_reason: "github_token_restored")
      end
    end

    context "with projects using a different token" do
      let(:other_token) { create(:github_token, account: account) }
      let!(:affected_project) do
        create(:project, account: account, github_token: github_token,
          scheduler_paused_at: 1.hour.ago,
          scheduler_pause_reason: "GitHub token '#{github_token.name}' failed validation: Bad credentials")
      end
      let!(:unaffected_project) do
        create(:project, account: account, github_token: other_token,
          scheduler_paused_at: 1.hour.ago,
          scheduler_pause_reason: "GitHub token '#{other_token.name}' failed validation: Bad credentials")
      end

      it "only resumes projects using the recovered token" do
        described_class.call(github_token: github_token)

        expect(affected_project.reload.scheduler_paused_at).to be_nil
        expect(unaffected_project.reload.scheduler_paused_at).to be_present
      end
    end
  end
end
