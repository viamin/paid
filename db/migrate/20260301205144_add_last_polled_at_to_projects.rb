# frozen_string_literal: true

class AddLastPolledAtToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :last_polled_at, :datetime
  end
end
