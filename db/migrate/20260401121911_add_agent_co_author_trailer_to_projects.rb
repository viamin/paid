# frozen_string_literal: true

class AddAgentCoAuthorTrailerToProjects < ActiveRecord::Migration[8.1]
  def change
    # :text rather than :string — the trailer is a freeform value (e.g.
    # "Co-Authored-By: Name <email>") with no practical length constraint.
    add_column :projects, :agent_co_author_trailer, :text
  end
end
