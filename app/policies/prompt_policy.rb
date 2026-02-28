# frozen_string_literal: true

class PromptPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    visible?
  end

  def new?
    create?
  end

  def create?
    return false if record.global?

    has_any_account_role?(:owner, :admin)
  end

  def edit?
    update?
  end

  def update?
    return false unless visible?
    return false if record.global?

    has_any_account_role?(:owner, :admin)
  end

  def destroy?
    return false unless visible?
    return false if record.global?

    has_account_role?(:owner)
  end

  def diff?
    show?
  end

  private

  def visible?
    return false unless user.present?
    return true if record.global?

    user_in_account?
  end

  def account_for_record
    record.account || user&.account
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(account_id: nil, project_id: nil)
        .or(scope.where(account: user.account))
    end

    private

    attr_reader :user, :scope
  end
end
