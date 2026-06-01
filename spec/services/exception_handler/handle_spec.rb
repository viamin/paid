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

    context "with per-fingerprint rate limiting" do
      let(:error) do
        e = RuntimeError.new("spam burst test error")
        e.set_backtrace([ "/app/services/knowledge/collector_runner.rb:95:in `collect'" ])
        e
      end
      let(:context) { { subsystem: :knowledge } }

      it "runs full pipeline on the 5th occurrence" do
        allow(ExceptionHandler::Classifier).to receive(:call).and_call_original
        allow(Notifications::Publish).to receive(:call)

        5.times { described_class.call(exception: error, account: account, context: context) }

        expect(ExceptionHandler::Classifier).to have_received(:call).exactly(5).times
        incident = ExceptionIncident.last
        expect(incident.occurrence_count).to eq(5)
      end

      it "fast-paths on the 6th occurrence, skipping classifier and notifications" do
        allow(ExceptionHandler::Classifier).to receive(:call).and_call_original
        allow(Notifications::Publish).to receive(:call)

        6.times { described_class.call(exception: error, account: account, context: context) }

        expect(ExceptionHandler::Classifier).to have_received(:call).exactly(5).times
        expect(Notifications::Publish).to have_received(:call).exactly(5).times

        incident = ExceptionIncident.last
        expect(incident.occurrence_count).to eq(6)
        expect(incident.last_occurred_at).to be_within(1.second).of(Time.current)
      end

      it "returns a rate-limited result on the 6th occurrence" do
        5.times { described_class.call(exception: error, account: account, context: context) }

        result = described_class.call(exception: error, account: account, context: context)

        expect(result).to be_success
        expect(result.message).to eq("Rate-limited (per-fingerprint cap)")
      end

      it "resets rate limiting after the window expires" do
        5.times { described_class.call(exception: error, account: account, context: context) }

        incident = ExceptionIncident.last
        incident.update_column(:last_occurred_at, 2.hours.ago)
        incident.update_column(:occurrence_count, 5)

        allow(ExceptionHandler::Classifier).to receive(:call).and_call_original

        described_class.call(exception: error, account: account, context: context)

        expect(ExceptionHandler::Classifier).to have_received(:call).once
      end

      it "does not produce a log_exception entry for rate-limited captures" do
        captured_log_count = 0
        allow(Rails.logger).to receive(:warn) do |args|
          captured_log_count += 1 if args.is_a?(Hash) && args[:message] == "exception_handler.captured"
        end

        5.times { described_class.call(exception: error, account: account, context: context) }
        count_after_five = captured_log_count

        described_class.call(exception: error, account: account, context: context)

        expect(captured_log_count).to eq(count_after_five)
      end

      it "still updates occurrence_count and last_occurred_at on fast-path" do
        5.times { described_class.call(exception: error, account: account, context: context) }

        incident_before = ExceptionIncident.last
        expect(incident_before.occurrence_count).to eq(5)

        travel_to(1.minute.from_now) do
          described_class.call(exception: error, account: account, context: context)
        end

        incident_after = ExceptionIncident.last
        expect(incident_after.occurrence_count).to eq(6)
        expect(incident_after.last_occurred_at).to be >= incident_before.last_occurred_at
      end
    end

    context "with per-account rate limiting" do
      let(:error) do
        e = RuntimeError.new("account cap test error")
        e.set_backtrace([ "/app/services/knowledge/collector_runner.rb:95:in `collect'" ])
        e
      end

      it "drops with zero DB writes past the account cap" do
        create(:exception_incident,
          account: account,
          occurrence_count: described_class::ACCOUNT_HOURLY_CAP,
          last_occurred_at: 1.minute.ago,
          action_taken: "notified",
          subsystem: "knowledge")

        expect {
          result = described_class.call(exception: error, account: account, context: { subsystem: :knowledge })

          expect(result).to be_success
          expect(result.action).to eq("logged")
          expect(result.message).to eq("Account hourly cap exceeded")
          expect(result.incident).to be_nil
        }.not_to change(ExceptionIncident, :count)
      end

      it "does not update any incident row when account cap is hit" do
        incident = create(:exception_incident,
          account: account,
          occurrence_count: described_class::ACCOUNT_HOURLY_CAP,
          last_occurred_at: 1.minute.ago,
          action_taken: "notified",
          subsystem: "knowledge")

        original_count = incident.occurrence_count
        original_timestamp = incident.last_occurred_at

        described_class.call(exception: error, account: account, context: { subsystem: :knowledge })

        incident.reload
        expect(incident.occurrence_count).to eq(original_count)
        expect(incident.last_occurred_at).to eq(original_timestamp)
      end

      it "allows captures under the cap" do
        create(:exception_incident,
          account: account,
          occurrence_count: described_class::ACCOUNT_HOURLY_CAP - 1,
          last_occurred_at: 1.minute.ago,
          action_taken: "notified",
          subsystem: "knowledge")

        allow(Notifications::Publish).to receive(:call)

        expect {
          result = described_class.call(exception: error, account: account, context: { subsystem: :knowledge })

          expect(result).to be_success
          expect(result.incident).to be_a(ExceptionIncident)
        }.to change(ExceptionIncident, :count).by(1)
      end

      it "does not count incidents outside the window toward the cap" do
        create(:exception_incident,
          account: account,
          occurrence_count: described_class::ACCOUNT_HOURLY_CAP,
          last_occurred_at: 2.hours.ago,
          action_taken: "notified",
          subsystem: "knowledge")

        allow(Notifications::Publish).to receive(:call)

        expect {
          result = described_class.call(exception: error, account: account, context: { subsystem: :knowledge })

          expect(result).to be_success
          expect(result.incident).to be_a(ExceptionIncident)
        }.to change(ExceptionIncident, :count).by(1)
      end

      it "logs a structured error when dropping due to account cap" do
        create(:exception_incident,
          account: account,
          occurrence_count: described_class::ACCOUNT_HOURLY_CAP,
          last_occurred_at: 1.minute.ago,
          action_taken: "notified",
          subsystem: "knowledge")

        allow(Rails.logger).to receive(:error)

        described_class.call(exception: error, account: account, context: { subsystem: :knowledge })

        expect(Rails.logger).to have_received(:error).with(
          hash_including(
            message: "exception_handler.account_cap_dropped",
            account_id: account.id,
            exception_class: "RuntimeError"
          )
        )
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
