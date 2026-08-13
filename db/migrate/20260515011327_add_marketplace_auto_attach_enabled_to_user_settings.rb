# frozen_string_literal: true

class AddMarketplaceAutoAttachEnabledToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :marketplace_auto_attach_enabled, :boolean,
      default: false,
      null: false,
      comment: "Whether this user opts their own agent runs into automatic and team-default marketplace attachments."
  end
end
