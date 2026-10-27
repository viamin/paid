# frozen_string_literal: true

class AddReopenReviewedByForeignKey < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :issues, :users, column: :reopen_reviewed_by_id, validate: false
  end
end
