# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionNotification do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  # These specs drain the queue with perform_enqueued_jobs. Creating a project
  # also enqueues EnqueueKnowledgeCollectionJob, which now files its own incident
  # on terminal failure, so each block is scoped to only: HandleExceptionJob to
  # keep the incident/IssueFiler assertions deterministic.

  describe "GoodJob terminal failure with allowlisted subsystem" do
    it "produces an ExceptionIncident with the correct subsystem" do
      allow(ExceptionHandler::IssueFiler).to receive(:call)

      perform_enqueued_jobs(only: HandleExceptionJob) do
        HandleExceptionJob.perform_later(
          account_id: account.id,
          exception_class: "RuntimeError",
          exception_message: "knowledge collector crashed",
          exception_backtrace: [ "/app/services/knowledge/collector_runner.rb:95:in `collect'" ],
          context: { subsystem: "knowledge", project_id: project.id }
        )
      end

      incident = ExceptionIncident.last
      expect(incident).to have_attributes(
        subsystem: "knowledge",
        exception_class: "RuntimeError",
        message: "knowledge collector crashed",
        account: account,
        project: project
      )
    end

    it "files a GitHub issue when project context exists" do
      allow(ExceptionHandler::IssueFiler).to receive(:call)

      perform_enqueued_jobs(only: HandleExceptionJob) do
        HandleExceptionJob.perform_later(
          account_id: account.id,
          exception_class: "RuntimeError",
          exception_message: "collector failure",
          exception_backtrace: [ "/app/services/knowledge/collector.rb:10" ],
          context: { subsystem: "knowledge", project_id: project.id }
        )
      end

      expect(ExceptionHandler::IssueFiler).to have_received(:call).once
    end
  end

  describe "GoodJob terminal failure with non-allowlisted subsystem" do
    it "produces an ExceptionIncident with 'general' subsystem" do
      allow(ExceptionHandler::IssueFiler).to receive(:call)

      perform_enqueued_jobs(only: HandleExceptionJob) do
        HandleExceptionJob.perform_later(
          account_id: account.id,
          exception_class: "RuntimeError",
          exception_message: "unknown failure",
          exception_backtrace: [ "/app/jobs/some_job.rb:10" ],
          context: { subsystem: "general" }
        )
      end

      incident = ExceptionIncident.last
      expect(incident).to have_attributes(
        subsystem: "general",
        action_taken: "notified"
      )
    end

    it "does NOT file a GitHub issue for 'general' subsystem" do
      allow(ExceptionHandler::IssueFiler).to receive(:call)

      perform_enqueued_jobs(only: HandleExceptionJob) do
        HandleExceptionJob.perform_later(
          account_id: account.id,
          exception_class: "RuntimeError",
          exception_message: "general failure",
          exception_backtrace: [ "/app/jobs/some_job.rb:10" ],
          context: { subsystem: "general" }
        )
      end

      expect(ExceptionHandler::IssueFiler).not_to have_received(:call)
    end
  end

  describe "EnqueueKnowledgeCollectionJob notification configuration" do
    it "declares notification_subsystem as 'knowledge'" do
      expect(EnqueueKnowledgeCollectionJob.notification_subsystem).to eq("knowledge")
    end

    it "returns the project_id from arguments" do
      job = EnqueueKnowledgeCollectionJob.new(42)
      expect(job.notification_project_id).to eq(42)
    end

    it "uses default max_attempts so rescue_from fires on first attempt for non-retried errors" do
      expect(EnqueueKnowledgeCollectionJob.max_attempts).to eq(1)
    end
  end

  describe "ApplicationJob rescue_from with Paid::ExceptionNotifier" do
    let(:knowledge_job_class) do
      Class.new(ApplicationJob) do
        self.notification_subsystem = "knowledge"
        self.max_attempts = 3

        def perform
          raise "collector error"
        end
      end
    end

    let(:general_job_class) do
      Class.new(ApplicationJob) do
        def perform
          raise "unhandled error"
        end
      end
    end

    before do
      stub_const("TestKnowledgeJob", knowledge_job_class)
      stub_const("TestGeneralJob", general_job_class)
    end

    it "enqueues HandleExceptionJob on terminal failure" do
      account = create(:account)

      job = knowledge_job_class.new
      job.executions = 2

      Current.account = account
      expect {
        expect { job.perform_now }.to raise_error(RuntimeError)
      }.to have_enqueued_job(HandleExceptionJob).with(
        hash_including(
          exception_class: "RuntimeError",
          context: hash_including(subsystem: "knowledge")
        )
      )
    ensure
      Current.account = nil
    end

    it "resolves the tenant account when Current.account is unset (GoodJob worker case)" do
      account = create(:account)
      # Account is derived from tenant context (e.g. a project_id argument),
      # not from an ambient Current.account, which is nil on a worker thread.
      worker_job_class = Class.new(ApplicationJob) do
        self.notification_subsystem = "knowledge"

        define_method(:perform) { raise "worker failure" }
        define_method(:tenant_account) { account }
        private :tenant_account
      end
      stub_const("TestWorkerJob", worker_job_class)

      job = worker_job_class.new
      job.executions = 0

      Current.account = nil
      expect {
        expect { job.perform_now }.to raise_error(RuntimeError)
      }.to have_enqueued_job(HandleExceptionJob).with(
        hash_including(account_id: account.id, exception_class: "RuntimeError")
      )
    ensure
      Current.account = nil
    end

    it "does not enqueue HandleExceptionJob on non-terminal failure" do
      job = knowledge_job_class.new
      job.executions = 0

      expect {
        expect { job.perform_now }.to raise_error(RuntimeError)
      }.not_to have_enqueued_job(HandleExceptionJob)
    end

    it "does not enqueue HandleExceptionJob for HandleExceptionJob failures" do
      expect {
        HandleExceptionJob.perform_now(
          account_id: -1,
          exception_class: "RuntimeError",
          exception_message: "test",
          exception_backtrace: []
        )
      }.not_to have_enqueued_job(HandleExceptionJob)
    end
  end

  describe "Current.account attribution" do
    it "attribute is passed through the notifier from job context" do
      allow(ExceptionHandler::IssueFiler).to receive(:call)

      perform_enqueued_jobs do
        Current.account = account

        HandleExceptionJob.perform_later(
          account_id: account.id,
          exception_class: "RuntimeError",
          exception_message: "context test",
          exception_backtrace: [ "/app/test.rb:1" ],
          context: { subsystem: "knowledge" }
        )
      ensure
        Current.account = nil
      end

      incident = ExceptionIncident.last
      expect(incident.account).to eq(account)
    end
  end
end
