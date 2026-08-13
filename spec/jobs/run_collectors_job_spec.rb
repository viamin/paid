# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunCollectorsJob do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }

  it "has a 20-minute perform_timeout so a hung job cannot deadlock the Rails reloader" do
    expect(described_class.perform_timeout).to eq(20.minutes.to_i)
  end

  describe "#perform" do
    context "when Docker is unavailable" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
      end

      it "delegates to Knowledge::CollectorRunner" do
        expect(Knowledge::CollectorRunner).to receive(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "main",
          committed_at: nil
        )

        described_class.new.perform(project.id, commit_sha)
      end

      it "accepts a custom branch" do
        expect(Knowledge::CollectorRunner).to receive(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "develop",
          committed_at: nil
        )

        described_class.new.perform(project.id, commit_sha, branch: "develop")
      end

      it "sets knowledge_status to ready when all collectors succeed" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [ { collector_type: "tree_sitter", status: "completed" } ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("ready")
      end

      it "sets knowledge_status to ready when some collectors are skipped" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [
            { collector_type: "tree_sitter", status: "completed" },
            { collector_type: "churn_hotspot", status: "skipped", reason: "maat binary not found" }
          ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("ready")
      end

      it "sets knowledge_status to failed when any collector fails" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [
            { collector_type: "tree_sitter", status: "completed" },
            { collector_type: "dependency", status: "failed" }
          ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("failed")
      end

      it "sets knowledge_status to collecting before running" do
        project.update!(knowledge_status: "pending")
        allow(Knowledge::CollectorRunner).to receive(:call) do
          expect(project.reload.knowledge_status).to eq("collecting")
          { results: [ { collector_type: "tree_sitter", status: "completed" } ] }
        end

        described_class.new.perform(project.id, commit_sha)
      end

      it "sets knowledge_status to failed when no collectors run" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(results: [])

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("failed")
      end

      it "keeps knowledge_status as collecting when any collector is in_progress" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_return(
          results: [
            { collector_type: "tree_sitter", status: "completed" },
            { collector_type: "dependency", status: "in_progress" }
          ]
        )

        described_class.new.perform(project.id, commit_sha)

        expect(project.reload.knowledge_status).to eq("collecting")
      end

      it "sets knowledge_status to failed and re-raises when runner raises" do
        allow(Knowledge::CollectorRunner).to receive(:call).and_raise(RuntimeError, "container exploded")

        expect {
          described_class.new.perform(project.id, commit_sha)
        }.to raise_error(RuntimeError, "container exploded")

        expect(project.reload.knowledge_status).to eq("failed")
      end
    end

    context "when Docker is available" do
      before do
        allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(true)
      end

      it "delegates to Knowledge::ContainerizedRunner" do
        expect(Knowledge::ContainerizedRunner).to receive(:call).with(
          project: project,
          commit_sha: commit_sha,
          branch: "main",
          committed_at: nil
        )

        described_class.new.perform(project.id, commit_sha)
      end
    end
  end

  describe "exception notification (RDR-039)" do
    include ActiveJob::TestHelper

    before do
      allow(Knowledge::ContainerizedRunner).to receive(:available?).and_return(false)
    end

    it "declares notification_subsystem as 'knowledge'" do
      expect(described_class.notification_subsystem).to eq("knowledge")
    end

    it "returns the project_id from the first argument for incident attribution" do
      expect(described_class.new(project.id, commit_sha).notification_project_id).to eq(project.id)
    end

    it "uses default max_attempts so the rescue_from hook fires on the first failure" do
      expect(described_class.max_attempts).to eq(1)
    end

    context "when the runner raises a terminal failure" do
      before do
        allow(Knowledge::CollectorRunner).to receive(:call).and_raise(RuntimeError, "collector crashed")
        allow(ExceptionHandler::IssueFiler).to receive(:call)
      end

      it "terminally fails the job (re-raises through the rescue_from hook)" do
        expect {
          described_class.perform_now(project.id, commit_sha)
        }.to raise_error(RuntimeError, "collector crashed")
      end

      it "produces an ExceptionIncident with subsystem 'knowledge' and the correct project" do
        expect {
          described_class.perform_now(project.id, commit_sha)
        }.to raise_error(RuntimeError)

        # The ApplicationJob terminal-failure hook enqueued HandleExceptionJob;
        # drain it so the ExceptionHandler pipeline records the incident.
        perform_enqueued_jobs(only: HandleExceptionJob)

        incident = ExceptionIncident.last
        expect(incident).to have_attributes(
          subsystem: "knowledge",
          exception_class: "RuntimeError",
          account: project.account,
          project: project
        )
      end

      it "enqueues exactly one HandleExceptionJob via the notifier (no manual duplicate)" do
        expect {
          expect {
            described_class.perform_now(project.id, commit_sha)
          }.to raise_error(RuntimeError)
        }.to have_enqueued_job(HandleExceptionJob).exactly(:once)
      end
    end
  end
end
