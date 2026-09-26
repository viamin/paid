# frozen_string_literal: true

class AddSchedulingToAppleVerificationAttempts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :apple_verification_attempts, :queue_entered_at, :datetime,
      comment: "Time an Apple verification attempt entered the fair admission queue." unless column_exists?(:apple_verification_attempts, :queue_entered_at)
    add_column :apple_verification_attempts, :admission_reserved_at, :datetime,
      comment: "Time the scheduler reserved the Apple worker slot for this attempt." unless column_exists?(:apple_verification_attempts, :admission_reserved_at)
    add_index :apple_verification_attempts, [ :status, :queue_entered_at, :id ],
      name: "idx_apple_attempts_fair_queue", algorithm: :concurrently unless index_exists?(:apple_verification_attempts, [ :status, :queue_entered_at, :id ], name: "idx_apple_attempts_fair_queue")
  end

  def down
    remove_index :apple_verification_attempts, name: "idx_apple_attempts_fair_queue", algorithm: :concurrently if index_exists?(:apple_verification_attempts, name: "idx_apple_attempts_fair_queue")
    remove_column :apple_verification_attempts, :admission_reserved_at if column_exists?(:apple_verification_attempts, :admission_reserved_at)
    remove_column :apple_verification_attempts, :queue_entered_at if column_exists?(:apple_verification_attempts, :queue_entered_at)
  end
end
