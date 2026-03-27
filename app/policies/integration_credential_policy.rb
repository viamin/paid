# frozen_string_literal: true

class IntegrationCredentialPolicy < ApplicationPolicy
  def revoke?
    update?
  end

  def destroy?
    revoke?
  end
end
