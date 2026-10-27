# frozen_string_literal: true

class ValidateReopenReviewedByForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :issues, :users, column: :reopen_reviewed_by_id
  end
end
