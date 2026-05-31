# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionHandler::Handle do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:project_context) { { project_id: project.id } }

  describe ".call" do
    context "with a transient exception" do
      it "logs but does not create an incident" do
        error = Net::OpenTimeout.new("execution expired")
        error.set_backtrace([ "/app/foo.rb:1:in `bar'" ])

        result = described_class.call(
          exception: error,
          account: account,
          context: { subsystem: :knowledge }
        )

        expect(result).to be_success
        expect(result.action).to eq("logged")
        expect(ExceptionIncident.count).to eq(0)
      end
    end

    context "with an actionable exception" do
      let(:error) do
        e = RuntimeError.new("collection failed unexpectedly")
        e.set_backtrace([ "/app/services/knowledge/collector_runner.rb:95:in `collect'" ])
        e
      end

      it "creates an exception incident" do
        allow(ExceptionHandler::IssueFiler).to receive(:call)
        expect {
          described_class.call(
            exception: error,
            account: account,
            context: { subsystem: :knowledge, project_id: project.id }
          )
        }.to change(ExceptionIncident, :count).by(1)
      end

      it "returns a successful result with the incident" do
        allow(ExceptionHandler::IssueFiler).to receive(:call)

        result = described_class.call(
          exception: error,
          account: account,
          context: { subsystem: :knowledge, project_id: project.id }
        )

        expect(result).to be_success
        expect(result.incident).to be_a(ExceptionIncident)
        expect(result.incident.subsystem).to eq("knowledge")
        expect(result.incident.exception_class).to eq("RuntimeError")
      end

      it "files an issue when project has a GitHub token" do
        client = instance_double(GithubClient)
        gh_issue = double(html_url: "https://github.com/o/r/issues/1", number: 1)
        allow(client).to receive(:create_issue).and_return(gh_issue)
        allow(ExceptionHandler::IssueFiler).to receive(:call).and_wrap_original do |method, **args|
          allow(args[:project]).to receive(:github_token).and_return(
            instance_double(GithubToken, client: client)
          )
          method.call(**args)
        end

        result = described_class.call(
          exception: error,
          account: account,
          context: { subsystem: :knowledge, project_id: project.id }
        )

        expect(result).to be_success
        expect(result.incident.github_issue_url).to eq("https://github.com/o/r/issues/1")
      end

      it "publishes a notification" do
        allow(Notifications::Publish).to receive(:call)

        described_class.call(
          exception: error,
          account: account,
          context: { subsystem: :knowledge }
        )

        expect(Notifications::Publish).to have_received(:call).with(
          a_hash_including(
            account: account,
            source: "exception_handler",
            severity: :warning
          )
        )
      end

      ExceptionHandler::Classifier::ISSUE_FILING_ALLOWLIST.each do |subsystem|
        it "files issues for the #{subsystem} subsystem" do
          filed_incident = nil
          filed_project = nil

          allow(ExceptionHandler::IssueFiler).to receive(:call) do |incident:, project:|
            filed_incident = incident
            filed_project = project
            incident.update!(action_taken: "issue_filed")
          end

          result = described_class.call(
            exception: error,
            account: account,
            context: project_context.merge(subsystem:)
          )

          expect(ExceptionHandler::IssueFiler).to have_received(:call).once
          expect(filed_project).to eq(project)
          expect(filed_incident.subsystem).to eq(subsystem)
          expect(result.incident.reload.action_taken).to eq("issue_filed")
        end
      end
    end

    context "with a non-allowlisted actionable exception" do
      let(:error) do
        e = RuntimeError.new("sync failed unexpectedly")
        e.set_backtrace([ "/app/services/github_sync/sync_runner.rb:12:in `run'" ])
        e
      end
      let(:context) { project_context.merge(subsystem: :github_sync) }

      def call_handler(error:, account:, context:)
        described_class.call(
          exception: error,
          account: account,
          context: context
        )
      end

      it "records the incident, skips issue filing, and still publishes a notification" do
        allow(ExceptionHandler::IssueFiler).to receive(:call)
        allow(Notifications::Publish).to receive(:call)

        result = call_handler(error: error, account: account, context: context)

        expect(result).to be_success
        expect(result.action).to eq("notified")
        expect(result.incident).to have_attributes(
          subsystem: "github_sync",
          action_taken: "notified"
        )
        expect(ExceptionHandler::IssueFiler).not_to have_received(:call)
        expect(Notifications::Publish).to have_received(:call).with(
          a_hash_including(
            account: account,
            source: "exception_handler",
            subject: result.incident
          )
        )
      end

      it "logs the effective notified action" do
        allow(ExceptionHandler::IssueFiler).to receive(:call)
        allow(Notifications::Publish).to receive(:call)
        allow(Rails.logger).to receive(:warn)

        call_handler(error: error, account: account, context: context)

        expect(Rails.logger).to have_received(:warn).with(
          a_hash_including(
            message: "exception_handler.captured",
            subsystem: "github_sync",
            action: "notified"
          )
        )
      end

      it "still logs the captured exception when notification publishing fails" do
        allow(ExceptionHandler::IssueFiler).to receive(:call)
        allow(Notifications::Publish).to receive(:call).and_raise("notify failed")
        allow(Rails.logger).to receive(:warn)
        allow(Rails.logger).to receive(:error)

        result = call_handler(error: error, account: account, context: context)

        expect(result).to be_failure
        expect(Rails.logger).to have_received(:warn).with(
          a_hash_including(
            message: "exception_handler.captured",
            subsystem: "github_sync",
            action: "notified"
          )
        )
        expect(Rails.logger).to have_received(:error).with(
          a_hash_including(
            message: "exception_handler.handle_failed",
            handler_error: "notify failed"
          )
        )
      end
    end

    context "with a duplicate exception" do
      let(:error) do
        e = RuntimeError.new("collection failed unexpectedly")
        e.set_backtrace([ "/app/services/knowledge/collector_runner.rb:95:in `collect'" ])
        e
      end

      it "increments occurrence count instead of creating a new incident" do
        described_class.call(exception: error, account: account, context: { subsystem: :knowledge })

        expect {
          described_class.call(exception: error, account: account, context: { subsystem: :knowledge })
        }.not_to change(ExceptionIncident, :count)

        expect(ExceptionIncident.last.occurrence_count).to eq(2)
      end
    end

    context "when the handler itself fails" do
      it "returns a failure result without raising" do
        allow(ExceptionHandler::Fingerprinter).to receive(:call).and_raise("handler bug")

        error = RuntimeError.new("original error")
        error.set_backtrace([])

        result = described_class.call(
          exception: error,
          account: account,
          context: { subsystem: :knowledge }
        )

        expect(result).to be_failure
        expect(result.message).to include("handler bug")
      end
    end
  end
end
