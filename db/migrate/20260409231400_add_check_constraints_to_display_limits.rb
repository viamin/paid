# frozen_string_literal: true

class AddCheckConstraintsToDisplayLimits < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :user_settings, "max_issues_per_page BETWEEN 5 AND 200", name: "chk_max_issues_per_page_bounds"
    add_check_constraint :user_settings, "max_prs_per_page BETWEEN 5 AND 200", name: "chk_max_prs_per_page_bounds"
  end
end
