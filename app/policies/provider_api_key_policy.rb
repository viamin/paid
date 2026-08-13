# frozen_string_literal: true

class ProviderApiKeyPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    owner?
  end

  def create?
    owner?
  end

  def new?
    create?
  end

  def edit?
    owner?
  end

  def update?
    owner?
  end

  def destroy?
    owner?
  end

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.where(user: user)
    end

    private

    attr_reader :user, :scope
  end

  private

  def owner?
    user.present? && record.user_id == user.id
  end
end
