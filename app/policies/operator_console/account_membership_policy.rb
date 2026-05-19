# frozen_string_literal: true

module OperatorConsole
  class AccountMembershipPolicy < BasePolicy
    def create?
      operator?
    end
  end
end
