# frozen_string_literal: true

class AddWebhookSecretToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :webhook_secret, :text
  end
end
