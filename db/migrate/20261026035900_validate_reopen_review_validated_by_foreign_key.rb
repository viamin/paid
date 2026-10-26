# frozen_string_literal: true

class ValidateReopenReviewValidatedByForeignKey < ActiveRecord::Migration[8.1]
  def change
    validate_foreign_key :issues, :users, column: :reopen_review_validated_by_id
  end
end
