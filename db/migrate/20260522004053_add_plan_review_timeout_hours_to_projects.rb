# frozen_string_literal: true

class AddPlanReviewTimeoutHoursToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :plan_review_timeout_hours, :integer,
      null: false,
      default: 24,
      comment: "Maximum hours to wait for plan review approval before auto-approving."
  end
end
