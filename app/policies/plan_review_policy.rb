# frozen_string_literal: true

class PlanReviewPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def manage?
    user.present?
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
      scope
    end
  end
end
