# frozen_string_literal: true

module Paid
  class ExceptionNotifier
    DEFAULT_SUBSYSTEM = "general"
    MAX_MESSAGE_LENGTH = 10_000
    MAX_BACKTRACE_FRAMES = 20

    def call(exception, options = {})
      data = normalized_hash(options&.fetch(:data, {}))
      account = data[:account] || Current.account
      return nil unless account

      context = pinned_context(data)
      exception_class = serialized_exception_class(exception)

      HandleExceptionJob.perform_later(
        account_id: account.id,
        exception_class: exception_class,
        exception_message: safe_message(exception).truncate(MAX_MESSAGE_LENGTH),
        exception_backtrace: exception.backtrace&.first(MAX_BACKTRACE_FRAMES),
        context: context
      )
    rescue => e
      Rails.logger.error(
        message: "exception_notifier.notify_failed",
        original_exception: exception.class.name,
        notifier_error: e.message
      )
      nil
    end

    private

    def pinned_context(data)
      extra_context = normalized_hash(data[:context]).except(:subsystem, :project_id)

      {
        subsystem: data[:subsystem] || DEFAULT_SUBSYSTEM,
        project_id: data[:project_id]
      }.merge(extra_context)
    end

    def normalized_hash(value)
      value.to_h.deep_symbolize_keys
    end

    def safe_message(exception)
      exception.message.to_s
    rescue
      "[#{serialized_exception_class(exception)} message raised]"
    end

    def serialized_exception_class(exception)
      exception.class.name || exception.class.superclass&.name || RuntimeError.name
    end
  end
end
