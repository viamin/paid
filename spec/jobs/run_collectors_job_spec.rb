# frozen_string_literal: true

require "rails_helper"

RSpec.describe RunCollectorsJob do
  let(:project) { create(:project) }
  let(:commit_sha) { "a" * 40 }

  # @spec KNOWLEDGE-001
  it "has a 45-minute perform_timeout for a complete bounded collection" do
    expect(described_class.perform_timeout).to eq(45.minutes.to_i)
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

      # @spec KNOWLEDGE-001
      it "keeps knowledge_status collecting when an artifact lock is unavailable for retry" do
        allow(Knowledge::CollectorRunner).to receive(:call)
          .and_raise(Knowledge::ArtifactStore::LockUnavailable, "lock unavailable")

        job = described_class.new(project.id, commit_sha)
        job.exception_executions = { "[Knowledge::ArtifactStore::LockUnavailable]" => 0 }

        expect { job.perform_now }.not_to raise_error
        expect(project.reload.knowledge_status).to eq("collecting")
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

    context "when artifact lock contention exhausts retries" do
      let(:notifier) { instance_double(Paid::ExceptionNotifier) }

      before do
        allow(Knowledge::CollectorRunner).to receive(:call)
          .and_raise(Knowledge::ArtifactStore::LockUnavailable, "lock unavailable")
        allow(Paid::ExceptionNotifier).to receive(:new).and_return(notifier)
        allow(notifier).to receive(:call)
      end

      # @spec KNOWLEDGE-001 EXCEPTION-NOTIFY-003
      it "marks the collection failed, notifies, and re-raises" do
        job = described_class.new(project.id, commit_sha)
        job.exception_executions = { "[Knowledge::ArtifactStore::LockUnavailable]" => 4 }

        expect { job.perform_now }.to raise_error(Knowledge::ArtifactStore::LockUnavailable, "lock unavailable")

        expect(project.reload.knowledge_status).to eq("failed")
        expect(notifier).to have_received(:call).with(
          an_instance_of(Knowledge::ArtifactStore::LockUnavailable),
          data: hash_including(subsystem: "knowledge", project_id: project.id)
        )
      end

      # @spec KNOWLEDGE-001
      # Reproduces the production timing gap directly on #mark_terminal_lock_failure:
      # by the time retry_on's exhaustion block runs, ApplicationJob's
      # around_perform has already unwound with_tenant_context, restoring the DB
      # session to no account/no bypass (TenantContext#with's ensure). The
      # :tenant_isolation tag opts this example out of rails_helper's blanket
      # system-access wrap so that gap isn't masked by the test harness.
      it "bypasses RLS for the project lookup even with no surrounding tenant context", :tenant_isolation do
        job = described_class.new(project.id, commit_sha)
        bypass_during_lookup = nil
        allow(Project).to receive(:find_by).and_wrap_original do |method, *args, **kwargs|
          bypass_during_lookup = current_bypass_setting
          method.call(*args, **kwargs)
        end

        bypass_before = current_bypass_setting
        job.send(:mark_terminal_lock_failure)

        expect(bypass_during_lookup).to eq("true")
        expect(current_bypass_setting).to eq(bypass_before)
        expect(project.reload.knowledge_status).to eq("failed")
      end
    end
  end

  def current_bypass_setting
    ActiveRecord::Base.connection.select_value("SELECT current_setting('paid.bypass_tenant_rls', true)")
  end
end
