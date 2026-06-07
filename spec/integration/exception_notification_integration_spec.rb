# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionNotification do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }

  describe "GoodJob terminal failure with allowlisted subsystem" do
    it "produces an ExceptionIncident with the correct subsystem" do
      allow(ExceptionHandler::IssueFiler).to receive(:call)

      perform_enqueued_jobs do
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

      perform_enqueued_jobs do
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

      perform_enqueued_jobs do
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

      perform_enqueued_jobs do
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

    it "sets max_attempts to match retry_on attempts" do
      expect(EnqueueKnowledgeCollectionJob.max_attempts).to eq(5)
    end
  end

  describe "retrying jobs align max_attempts with retry_on attempts" do
    # Without this, jobs declaring retry_on would inherit the default
    # max_attempts of 1 and could notify before Active Job exhausts retries.
    {
      AgentRunCancellationJob => 5,
      AgentRunResourceJanitorJob => 3,
      DependencyBackfillJob => 3,
      EmbedChunksJob => 5,
      GithubTokenValidationJob => 3,
      QdrantCollectionCleanupJob => 5
    }.each do |job_class, expected|
      it "#{job_class} declares max_attempts == #{expected}" do
        expect(job_class.max_attempts).to eq(expected)
      end
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
