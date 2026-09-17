# frozen_string_literal: true

# @spec TENANT-ACCESS-001
# @spec FEATURE-APPROVAL-012
# Any project member may see and approve a feature intent's design decision
# — RDR-066 deliberately does not restrict Mark approved to project
# admins/owners the way plan-review actions are ("Any project member with
# Inbox access may approve"). Delegates to ProjectPolicy so this stays in
# sync with the project's general membership rules.
class FeatureIntentPolicy < ApplicationPolicy
  def show?
    ProjectPolicy.new(user, record.project).show?
  end

  def approve?
    ProjectPolicy.new(user, record.project).manage_issues?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      raise Pundit::NotAuthorizedError, "must be logged in" unless user

      scope.joins(:project).merge(ProjectPolicy::Scope.new(user, Project).resolve)
    end
  end
end
