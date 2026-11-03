# frozen_string_literal: true

class DefaultNewProjectsToReadOnlyLabelIntegration < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :label_integration_mode, from: "read_write", to: "read_only"
  end
end
