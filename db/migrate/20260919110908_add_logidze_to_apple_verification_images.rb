# frozen_string_literal: true

class AddLogidzeToAppleVerificationImages < ActiveRecord::Migration[8.1]
  def up
    add_logidze_history_column
    create_logidze_trigger
  end

  def down
    drop_logidze_trigger
    remove_column :apple_verification_images, :log_data if column_exists?(:apple_verification_images, :log_data)
  end

  private

  def add_logidze_history_column
    return if column_exists?(:apple_verification_images, :log_data)

    add_column :apple_verification_images, :log_data, :jsonb, comment: "Logidze change history for Apple verification image lifecycle transitions."
  end

  def create_logidze_trigger
    return if trigger_exists?("logidze_on_apple_verification_images")

    create_trigger :logidze_on_apple_verification_images, on: :apple_verification_images
  end

  def drop_logidze_trigger
    execute <<~SQL
      DROP TRIGGER IF EXISTS "logidze_on_apple_verification_images" on "apple_verification_images";
    SQL
  end

  def trigger_exists?(name)
    connection.select_value("SELECT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = #{connection.quote(name)})")
  end
end
