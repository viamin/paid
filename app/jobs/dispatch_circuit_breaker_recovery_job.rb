# frozen_string_literal: true

class DispatchCircuitBreakerRecoveryJob < ApplicationJob
  queue_as :maintenance

  def perform
    ::DispatchCircuitBreaker.open_circuits.includes(:account).find_each do |breaker|
      breaker.check_recovery!
    rescue => e
      Rails.logger.warn(
        message: "dispatch_circuit_breaker_recovery.check_error",
        account_id: breaker.account_id,
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(200)
      )
    end
  end
end
