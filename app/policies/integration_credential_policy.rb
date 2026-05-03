# frozen_string_literal: true

class IntegrationCredentialPolicy < ApplicationPolicy
  def index?
    has_any_account_role?(:owner, :admin)
  end

  def show?
    has_any_account_role?(:owner, :admin)
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_any_account_role?(:owner, :admin)
  end

  def revoke?
    destroy?
  end

  private

  def account_for_record
    record.respond_to?(:account) ? record.account : user&.account
  end
end
