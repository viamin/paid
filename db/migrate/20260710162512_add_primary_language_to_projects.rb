# frozen_string_literal: true

class AddPrimaryLanguageToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :primary_language, :string,
      comment: "Primary language of the repository as reported by GitHub (e.g. Ruby, Elixir, Swift). Used to detect and badge the project type."
  end
end
