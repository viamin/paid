# frozen_string_literal: true

class RunnerPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def create?
    owner?
  end

  def new?
    create?
  end

  def update?
    owner?
  end

  def edit?
    update?
  end

  def destroy?
    owner?
  end

  def test_agent?
    owner?
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.kept_only.where(user: user)
    end

    private

    attr_reader :user, :scope
  end

  private

  def owner?
    user.present? && record.user_id == user.id
  end
end
