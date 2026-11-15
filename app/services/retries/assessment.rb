# frozen_string_literal: true

module Retries
  # Eligibility outcome shared by retry policies adopting Retries::Attempt.
  # @spec AGENT-RETRY-015
  Assessment = Data.define(:eligible?, :reason, :attempt_number)
end
