# frozen_string_literal: true

class AccountPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    user.has_role?(:owner, record)
  end

  def manage_billing?
    user.has_role?(:owner, record)
  end

  private

  def user_in_account?
    user.account_id == record.id
  end

  def account_for_record
    record
  end
end
