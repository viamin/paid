# frozen_string_literal: true

require "rails_helper"

RSpec.describe HandleExceptionJob do
  let(:account) { create(:account) }

  describe "#perform" do
    it "calls ExceptionHandler::Handle with a reconstructed exception" do
      allow(ExceptionHandler::Handle).to receive(:call)
        .and_return(ExceptionHandler::Handle::Result.new(success: true, action: "logged"))

      described_class.perform_now(
        account_id: account.id,
        exception_class: "RuntimeError",
        exception_message: "test failure",
        exception_backtrace: [ "/app/foo.rb:1:in `bar'" ],
        context: { "subsystem" => "knowledge" }
      )

      expect(ExceptionHandler::Handle).to have_received(:call).with(
        exception: an_instance_of(RuntimeError),
        account: account,
        context: a_hash_including(subsystem: "knowledge")
      )
    end

    it "reconstructs the exception with correct class and message" do
      captured_exception = nil
      allow(ExceptionHandler::Handle).to receive(:call) { |exception:, **|
        captured_exception = exception
        ExceptionHandler::Handle::Result.new(success: true, action: "logged")
      }

      described_class.perform_now(
        account_id: account.id,
        exception_class: "ArgumentError",
        exception_message: "wrong number of arguments",
        exception_backtrace: [ "/app/bar.rb:5" ]
      )

      expect(captured_exception).to be_a(ArgumentError)
      expect(captured_exception.message).to eq("wrong number of arguments")
      expect(captured_exception.backtrace).to eq([ "/app/bar.rb:5" ])
    end

    it "falls back to RuntimeError for unknown exception classes" do
      captured_exception = nil
      allow(ExceptionHandler::Handle).to receive(:call) { |exception:, **|
        captured_exception = exception
        ExceptionHandler::Handle::Result.new(success: true, action: "logged")
      }

      described_class.perform_now(
        account_id: account.id,
        exception_class: "NonExistent::Error",
        exception_message: "something",
        exception_backtrace: []
      )

      expect(captured_exception).to be_a(RuntimeError)
    end

    it "falls back to RuntimeError when exception class requires extra arguments" do
      stub_const("StrictError", Class.new(StandardError) do
        def initialize(provider:)
          super("provider #{provider} expired")
        end
      end)

      captured_exception = nil
      allow(ExceptionHandler::Handle).to receive(:call) { |exception:, **|
        captured_exception = exception
        ExceptionHandler::Handle::Result.new(success: true, action: "logged")
      }

      described_class.perform_now(
        account_id: account.id,
        exception_class: "StrictError",
        exception_message: "provider expired",
        exception_backtrace: [ "/app/baz.rb:10" ]
      )

      expect(captured_exception).to be_a(RuntimeError)
      expect(captured_exception.message).to eq("[StrictError] provider expired")
      expect(captured_exception.backtrace).to eq([ "/app/baz.rb:10" ])
    end

    it "discards on missing account" do
      expect {
        described_class.perform_now(
          account_id: -1,
          exception_class: "RuntimeError",
          exception_message: "test",
          exception_backtrace: []
        )
      }.not_to raise_error
    end
  end
end
