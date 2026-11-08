# frozen_string_literal: true

module OperatorConsole
  class AccountActivityEventPolicy < BasePolicy
    # @spec PROJECT-DELEGATION-001
    def update?
      false
    end
  end
end
