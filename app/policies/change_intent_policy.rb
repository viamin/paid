# frozen_string_literal: true

class ChangeIntentPolicy < ApplicationPolicy
  def show?
    ProjectPolicy.new(user, record.project).show?
  end

  def create?
    ProjectPolicy.new(user, record.project).update?
  end

  def update?
    create?
  end

  def destroy?
    create?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:project).merge(ProjectPolicy::Scope.new(user, Project).resolve)
    end
  end

  private

  def account_for_record
    record.project.account
  end
end
