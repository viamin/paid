# frozen_string_literal: true

module ChatSessions
  module ErrorMessage
    module_function

    def for(error)
      case error
      when AgentHarness::RateLimitError
        rate_limit_message(error)
      else
        error.message
      end
    end

    def rate_limit_message(error)
      reset_time = error.respond_to?(:reset_time) ? error.reset_time : nil
      return error.message if reset_time.blank?

      "#{error.message} (resets at #{I18n.l(reset_time, format: :long)})"
    end
  end
end
