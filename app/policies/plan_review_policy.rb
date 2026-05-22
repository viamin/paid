# frozen_string_literal: true

class PlanReviewPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def manage?
    ProjectPolicy.new(user, record.project).show?
  end

  def approve?
    manage?
  end

  def reject?
    manage?
  end

  def revise?
    manage?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:project).merge(ProjectPolicy::Scope.new(user, Project).resolve)
    end
  end
end
