# frozen_string_literal: true

class AddRoutePathToPageLoadRegressionFindings < ActiveRecord::Migration[8.1]
  def change
    add_column :page_load_regression_findings, :route_path, :string, limit: 2048,
      comment: "Path the regressed route resolved to when the finding was raised; copied into the follow-up run's prompt so the agent can reproduce and diagnose the regression."
  end
end
