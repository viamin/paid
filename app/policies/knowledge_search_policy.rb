# frozen_string_literal: true

class KnowledgeSearchPolicy < ApplicationPolicy
  # Users can search knowledge for projects they have access to.
  # Access requires account membership (same as ProjectPolicy#show?)
  # or an explicit project-level role.
  def search?
    user_in_account? || has_project_role?
  end

  private

  def has_project_role?
    return false unless user && record.is_a?(Project)

    user.has_any_role?(:project_admin, :project_member, record)
  end
end
