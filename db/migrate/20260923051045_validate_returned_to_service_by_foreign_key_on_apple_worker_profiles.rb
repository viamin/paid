# frozen_string_literal: true

class ValidateReturnedToServiceByForeignKeyOnAppleWorkerProfiles < ActiveRecord::Migration[8.1]
  def up
    validate_foreign_key :apple_worker_profiles, column: :returned_to_service_by_id
  end

  def down
    # Validation does not create a separate schema object; the creating migration owns removal.
  end
end
