# frozen_string_literal: true

require "rails_helper"

RSpec.describe ExceptionNotification::Rack do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    original_ignored_exceptions = ExceptionNotifier.ignored_exceptions

    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    Current.account = nil
    ExceptionNotifier.clear_ignore_conditions!
    ExceptionNotifier.unregister_exception_notifier(:paid)

    example.run
  ensure
    ExceptionNotifier.unregister_exception_notifier(:paid)
    ExceptionNotifier.ignored_exceptions = original_ignored_exceptions
    ExceptionNotifier.clear_ignore_conditions!
    clear_enqueued_jobs
    Current.account = nil
    ActiveJob::Base.queue_adapter = original_adapter
  end

  it "captures a web-request exception and attributes Current.account" do
    middleware = described_class.new(rack_app, ignore_exceptions: [], paid: Paid::ExceptionNotifier.new)

    expect_request_exception(middleware)
    expect_enqueued_exception_job
    expect_recorded_incident
  end

  private

  def rack_app
    account = self.account

    lambda do |_env|
      Current.account = account
      raise RuntimeError, "request exploded"
    end
  end

  def expect_request_exception(middleware)
    expect {
      middleware.call(Rack::MockRequest.env_for("/boom"))
    }.to raise_error(RuntimeError, "request exploded")
  end

  def expect_enqueued_exception_job
    expect(enqueued_jobs.last[:args].first).to include(
      "account_id" => account.id,
      "exception_class" => "RuntimeError",
      "exception_message" => "request exploded"
    )
  end

  def expect_recorded_incident
    perform_enqueued_jobs(only: HandleExceptionJob)

    incident = ExceptionIncident.last
    expect(incident).to have_attributes(
      account: account,
      subsystem: "general",
      exception_class: "RuntimeError",
      message: "request exploded"
    )
  end
end
