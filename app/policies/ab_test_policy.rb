# frozen_string_literal: true

class AbTestPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user_in_account?
  end

  def create?
    has_any_account_role?(:owner, :admin)
  end

  def update?
    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    has_account_role?(:owner)
  end

  class Scope < ApplicationPolicy::Scope
  end
end
