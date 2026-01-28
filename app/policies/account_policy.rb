# frozen_string_literal: true

class AccountPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_account_role?(:owner)
  end

  def manage_billing?
    has_account_role?(:owner)
  end

  private

  def user_in_account?
    user&.account_id == record.id
  end
end
