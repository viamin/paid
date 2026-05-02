# frozen_string_literal: true

class IssueMergeSubscriptionPolicy < ApplicationPolicy
  def create?
    allowed?
  end

  def destroy?
    allowed?
  end

  private

  def allowed?
    record.github_state == "open" && ProjectPolicy.new(user, record.project).show?
  end

  def account_for_record
    record.project.account
  end
end
