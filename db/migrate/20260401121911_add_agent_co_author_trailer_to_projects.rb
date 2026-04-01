# frozen_string_literal: true

class AddAgentCoAuthorTrailerToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :agent_co_author_trailer, :string
  end
end
