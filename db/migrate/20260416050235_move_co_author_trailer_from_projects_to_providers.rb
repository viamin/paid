# frozen_string_literal: true

class MoveCoAuthorTrailerFromProjectsToProviders < ActiveRecord::Migration[8.1]
  def change
    # The trailer moves from the project level to the provider level so that
    # attribution reflects the provider that actually produced the commit,
    # including after provider fallback. :text matches the original column;
    # the trailer is a freeform value (e.g. "Co-Authored-By: Name <email>")
    # with no practical length constraint.
    add_column :providers, :agent_co_author_trailer, :text

    remove_column :projects, :agent_co_author_trailer, :text
  end
end
