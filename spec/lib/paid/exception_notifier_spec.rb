# frozen_string_literal: true

require "rails_helper"

RSpec.describe Paid::ExceptionNotifier do # @spec EXCEPTION-NOTIFY-001 # @spec EXCEPTION-NOTIFY-002
  include ActiveJob::TestHelper

  subject(:notifier) { described_class.new }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:exception) { RuntimeError.new("boom") }

  around do |example|
    original_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    Current.account = nil

    example.run
  ensure
    clear_enqueued_jobs
    Current.account = nil
    ActiveJob::Base.queue_adapter = original_adapter
  end

  def last_job_args
    enqueued_jobs.last[:args].first
  end

  def last_job_context
    last_job_args["context"].except("_aj_symbol_keys").symbolize_keys
  end

  describe "#call" do
    it "enqueues HandleExceptionJob with truncated exception payload and merged context" do
      Current.account = account
      exception.set_backtrace(Array.new(25) { |index| "frame-#{index}" })
      long_message = "x" * 10_500
      allow(exception).to receive(:message).and_return(long_message)

      notifier.call(exception, data: notification_data(request_id: "req-123"))

      expect(last_job_args["account_id"]).to eq(account.id)
      expect(last_job_args["exception_class"]).to eq("RuntimeError")
      expect(last_job_args["exception_message"]).to eq(long_message.truncate(10_000))
      expect(last_job_args["exception_backtrace"]).to eq(Array.new(20) { |index| "frame-#{index}" })
      expect(last_job_context).to eq({
        subsystem: "knowledge",
        project_id: project.id,
        request_id: "req-123"
      })
    end

    it "returns nil without enqueueing when no account is available" do
      result = nil

      expect {
        result = notifier.call(exception, data: { subsystem: "knowledge", project_id: project.id })
      }.not_to have_enqueued_job(HandleExceptionJob)

      expect(result).to be_nil
    end

    it "does not allow nested context to override pinned subsystem or project_id" do
      Current.account = account

      notifier.call(
        exception,
        data: notification_data(
          request_id: "req-456",
          context: { subsystem: "general", project_id: -1, request_id: "req-456" }
        )
      )

      expect(last_job_context).to eq({
        subsystem: "knowledge",
        project_id: project.id,
        request_id: "req-456"
      })
    end

    it "swallows internal notifier failures and logs them" do
      Current.account = account
      allow(HandleExceptionJob).to receive(:perform_later).and_raise("enqueue failed")
      allow(Rails.logger).to receive(:error)

      expect(notifier.call(exception, data: { subsystem: "knowledge" })).to be_nil
      expect(Rails.logger).to have_received(:error).with(
        hash_including(
          message: "exception_notifier.notify_failed",
          original_exception: "RuntimeError",
          notifier_error: "enqueue failed"
        )
      )
    end

    it "falls back when exception.message itself raises for anonymous exception classes" do
      Current.account = account

      broken_exception = Class.new(StandardError) do
        def message
          raise "broken message"
        end
      end.new

      expect {
        notifier.call(broken_exception, data: { subsystem: "knowledge" })
      }.to have_enqueued_job(HandleExceptionJob).with(
        hash_including(
          exception_class: "StandardError",
          exception_message: "[StandardError message raised]"
        )
      )
    end

    it "truncates backtrace to the first 20 frames" do
      Current.account = account
      exception.set_backtrace(Array.new(30) { |index| "line-#{index}" })

      notifier.call(exception, data: { subsystem: "knowledge" })

      job = enqueued_jobs.last
      expect(job[:args].first["exception_backtrace"]).to eq(Array.new(20) { |index| "line-#{index}" })
    end
  end

  def notification_data(request_id:, context: { request_id: })
    {
      subsystem: "knowledge",
      project_id: project.id,
      context: context
    }
  end
end
