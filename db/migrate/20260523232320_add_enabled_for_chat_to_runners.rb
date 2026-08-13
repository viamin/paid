# frozen_string_literal: true

class AddEnabledForChatToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :enabled_for_chat, :boolean, default: true, null: false,
      comment: "Whether the runner is eligible to back interactive chat sessions."
  end
end
