# frozen_string_literal: true

class HandleExceptionJob < ApplicationJob
  queue_as :default
  discard_on ActiveRecord::RecordNotFound
  retry_on ExceptionHandler::IssueFiler::RetryableFilingInProgress,
    wait: 2.seconds,
    attempts: (ExceptionHandler::IssueFiler::CLAIM_STALE_AFTER / 2.seconds).ceil

  # Accepts serialized exception data since exceptions themselves are not
  # serializable through Active Job.
  def perform(account_id:, exception_class:, exception_message:, exception_backtrace:, context: {})
    account = Account.find(account_id)
    exception = reconstruct_exception(exception_class, exception_message, exception_backtrace)

    ExceptionHandler::Handle.call(
      exception: exception,
      account: account,
      context: context.symbolize_keys
    )
  end

  private

  def reconstruct_exception(klass_name, message, backtrace)
    klass = klass_name.safe_constantize || RuntimeError
    exception = begin
      klass.new(message)
    rescue ArgumentError
      RuntimeError.new("[#{klass_name}] #{message}")
    end
    exception.set_backtrace(Array(backtrace))
    exception
  end
end
