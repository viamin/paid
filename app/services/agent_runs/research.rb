# frozen_string_literal: true

module AgentRuns
  module Research
    class Error < StandardError
      attr_reader :status

      def initialize(message, status: :unprocessable_entity)
        super(message)
        @status = status
      end
    end

    class ForbiddenError < Error
      def initialize(message = "This agent run is not allowed to use brokered research")
        super(message, status: :forbidden)
      end
    end

    class BudgetExceededError < Error
      def initialize(message = "Research budget exceeded for this agent run")
        super(message, status: :too_many_requests)
      end
    end

    class RequestInvalidError < Error; end
    class UpstreamError < Error
      def initialize(message = "Brokered research request failed")
        super(message, status: :bad_gateway)
      end
    end
  end
end
