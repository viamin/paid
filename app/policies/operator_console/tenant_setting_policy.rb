# frozen_string_literal: true

module OperatorConsole
  class TenantSettingPolicy < BasePolicy
    def create?
      operator?
    end
  end
end
