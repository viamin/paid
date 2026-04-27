# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteIssueGoalActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }

  describe "#execute" do
    context "when the agent created an issue" do
      let(:github_client) { instance_double(GithubClient) }

      before do
        allow(GithubClient).to receive(:new).and_return(github_client)
        allow(github_client).to receive(:add_labels_to_issue)
      end

      it "marks the agent run as completed with issue details" do
        agent_run = create(:agent_run, :running, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.created_issue_url).to eq("https://github.com/example/repo/issues/42")
        expect(agent_run.created_issue_number).to eq(42)
        expect(result[:success]).to be true
        expect(result[:issue_created]).to be true
      end

      it "logs the completion" do
        agent_run = create(:agent_run, :running, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        activity.execute(agent_run_id: agent_run.id)

        logs = agent_run.agent_run_logs.pluck(:content)
        expect(logs).to include(a_string_including("issue #42 created"))
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        expect { activity.execute(agent_run_id: agent_run.id) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end

      it "does not log or enqueue when the run is already cancelled" do
        agent_run = create(:agent_run, :cancelled, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        expect {
          expect {
            activity.execute(agent_run_id: agent_run.id)
          }.not_to change(AgentRunLog, :count)
        }.not_to have_enqueued_job(ProcessRunQueueJob)
      end

      it "reports finished runs as skipped" do
        agent_run = create(:agent_run, :cancelled, project: project,
          created_issue_url: "https://github.com/example/repo/issues/42",
          created_issue_number: 42)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result).to include(
          success: false,
          issue_created: true,
          skipped: true,
          finished: true,
          cancelled: true
        )
      end

      context "with a priority tier" do
        it "applies the priority label to the created GitHub issue" do
          agent_run = create(:agent_run, :running, project: project,
            priority_tier: "P1",
            created_issue_url: "https://github.com/example/repo/issues/42",
            created_issue_number: 42)

          activity.execute(agent_run_id: agent_run.id)

          expect(github_client).to have_received(:add_labels_to_issue)
            .with(project.full_name, 42, [ "P1" ])
        end

        it "uses the project custom priority label name" do
          project.update!(priority_labels: { "P1" => "critical" })
          agent_run = create(:agent_run, :running, project: project,
            priority_tier: "P1",
            created_issue_url: "https://github.com/example/repo/issues/42",
            created_issue_number: 42)

          activity.execute(agent_run_id: agent_run.id)

          expect(github_client).to have_received(:add_labels_to_issue)
            .with(project.full_name, 42, [ "critical" ])
        end

        it "logs the label application" do
          agent_run = create(:agent_run, :running, project: project,
            priority_tier: "P2",
            created_issue_url: "https://github.com/example/repo/issues/42",
            created_issue_number: 42)

          activity.execute(agent_run_id: agent_run.id)

          logs = agent_run.agent_run_logs.pluck(:content)
          expect(logs).to include(a_string_including("Applied priority label: P2"))
        end

        it "logs and re-raises when label application fails" do
          allow(github_client).to receive(:add_labels_to_issue)
            .and_raise(GithubClient::Error, "Not Found")

          agent_run = create(:agent_run, :running, project: project,
            priority_tier: "P1",
            created_issue_url: "https://github.com/example/repo/issues/42",
            created_issue_number: 42)

          expect { activity.execute(agent_run_id: agent_run.id) }
            .to raise_error(GithubClient::Error, "Not Found")

          logs = agent_run.agent_run_logs.pluck(:content)
          expect(logs).to include(a_string_including("Failed to apply priority label"))
        end
      end

      context "without a priority tier" do
        it "does not call the GitHub labels API" do
          agent_run = create(:agent_run, :running, project: project,
            created_issue_url: "https://github.com/example/repo/issues/42",
            created_issue_number: 42)

          activity.execute(agent_run_id: agent_run.id)

          expect(github_client).not_to have_received(:add_labels_to_issue)
        end
      end
    end

    context "when the agent did not create an issue" do
      it "returns issue_created: false without failing the run" do
        agent_run = create(:agent_run, :running, project: project)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be true
        expect(result[:issue_created]).to be false
        expect(agent_run.reload.status).to eq("running")
      end

      it "logs the fallback message" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.content).to include("falling back to platform issue creation")
      end

      it "does not enqueue ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, project: project)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.not_to have_enqueued_job(ProcessRunQueueJob)
      end

      it "reports cancelled runs as skipped instead of fallback candidates" do
        agent_run = create(:agent_run, :cancelled, project: project)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result).to include(
          success: false,
          issue_created: false,
          skipped: true,
          finished: true,
          cancelled: true
        )
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
