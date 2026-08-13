# frozen_string_literal: true

module OperatorConsole
  class ProjectMembershipPolicy < BasePolicy
    def create?
      operator?
    end
  end
end
