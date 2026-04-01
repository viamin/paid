# frozen_string_literal: true

class PreCommitRequirementPolicy < ApplicationPolicy
  def index?
    user_in_account?
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
    has_any_account_role?(:owner, :admin)
  end

  private

  def account_for_record
    record.account
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(account: user.account)
    end

    private

    attr_reader :user, :scope
  end
end
