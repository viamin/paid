# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::HandleNoOutputIssueRunActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, label_mappings: { "build" => "paid-build", "needs_input" => "paid-needs-input" }) }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:recent_issue_comments).and_return([])
    allow(client).to receive(:add_comment)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:remove_label_from_issue)
  end

  describe "#execute" do
    context "when output_present is false (needs_input)" do
      it "sets issue paid_state to needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(issue.reload.paid_state).to eq("needs_input")
      end

      it "marks agent run as completed" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
      end

      it "adds the paid-needs-input label" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_labels_to_issue)
          .with(project.full_name, issue.github_number, [ "paid-needs-input" ])
      end

      it "posts a needs-input comment on the issue" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_comment)
          .with(project.full_name, issue.github_number, a_string_including("Needs Input"))
      end

      it "includes next-step instructions in the comment" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).to have_received(:add_comment)
          .with(project.full_name, issue.github_number,
            a_string_including("paid-needs-input").and(a_string_including("paid-build")))
      end

      it "logs the completion reason as needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        log = agent_run.agent_run_logs.find_by(log_type: "system")
        expect(log.content).to include("needs_input")
      end

      it "returns outcome needs_input" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(result[:outcome]).to eq("needs_input")
      end

      it "enqueues ProcessRunQueueJob" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        expect { activity.execute(agent_run_id: agent_run.id, output_present: false) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end
    end

    context "when output_present is true (recommend_close)" do
      it "sets issue paid_state to recommend_close" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(issue.reload.paid_state).to eq("recommend_close")
      end

      it "posts a recommend-close comment on the issue" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).to have_received(:add_comment)
          .with(project.full_name, issue.github_number, a_string_including("Recommend Close"))
      end

      it "does not add the paid-needs-input label" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).not_to have_received(:add_labels_to_issue)
      end

      it "returns outcome recommend_close" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(result[:outcome]).to eq("recommend_close")
      end
    end

    context "when agent run has no issue" do
      it "marks the run completed without posting comments" do
        agent_run = create(:agent_run, :running, project: project, issue: nil,
          custom_prompt: "Test prompt")

        result = activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
        expect(result[:outcome]).to eq("no_changes")
        expect(client).not_to have_received(:add_comment)
      end
    end

    context "when a comment marker already exists" do
      it "skips posting needs-input comment if marker already exists" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        existing_comment = Struct.new(:body).new(body: "<!-- paid:needs-input -->\nOld comment")
        allow(client).to receive(:recent_issue_comments).and_return([ existing_comment ])

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(client).not_to have_received(:add_comment)
      end

      it "skips posting recommend-close comment if marker already exists" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        existing_comment = Struct.new(:body).new(body: "<!-- paid:recommend-close -->\nOld comment")
        allow(client).to receive(:recent_issue_comments).and_return([ existing_comment ])

        activity.execute(agent_run_id: agent_run.id, output_present: true)

        expect(client).not_to have_received(:add_comment)
      end
    end

    context "when GitHub API returns errors" do
      it "completes the run even when comment posting fails" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        allow(client).to receive(:add_comment).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
        expect(issue.reload.paid_state).to eq("needs_input")
      end

      it "completes the run even when label adding fails" do
        issue = create(:issue, :in_progress, project: project)
        agent_run = create(:agent_run, :running, project: project, issue: issue)

        allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error, "API error")

        activity.execute(agent_run_id: agent_run.id, output_present: false)

        expect(agent_run.reload.status).to eq("completed")
      end
    end
  end
end
