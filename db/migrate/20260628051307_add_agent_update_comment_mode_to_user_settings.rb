# frozen_string_literal: true

class AddAgentUpdateCommentModeToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :agent_update_comment_mode, :string,
      default: "off",
      null: false,
      comment: "Controls whether existing-PR agent followups post no comment or generate a paid summary comment."
  end
end
