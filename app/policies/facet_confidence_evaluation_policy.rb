# frozen_string_literal: true

# Authorization for the facet-confidence closeout-evaluation workflow (#4596).
# Every action stays inside the project's existing tenant boundary; only the
# operator who started the evaluation (its sole reference judge) may record or
# freeze reference judgments, while any project operator may start one.
# @spec FACET-CONFIDENCE-020
# @spec FACET-CONFIDENCE-021
class FacetConfidenceEvaluationPolicy < ApplicationPolicy
  def show?
    user_in_account?
  end

  def create?
    operator?
  end

  def label?
    judge? && operator?
  end

  # Skipping is a judgment action with the same boundary as recording one.
  def skip?
    label?
  end

  def freeze?
    judge? && operator?
  end

  def revise?
    freeze?
  end

  private

  def project
    record.is_a?(FacetConfidenceEvaluation) ? record.project : record
  end

  # The evaluation has no direct account column; tenancy is keyed through
  # its project.
  def account_for_record
    project.account
  end

  def operator?
    return false unless user_in_account?

    has_any_account_role?(:owner, :admin, :member)
  end

  def judge?
    record.is_a?(FacetConfidenceEvaluation) && record.created_by_id == user&.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.joins(:project).where(projects: { account_id: user.account_id })
    end
  end
end
