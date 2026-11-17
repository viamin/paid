# frozen_string_literal: true

class RemoveUniqueLayeredVerificationReviewPackageDigestIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_layered_verification_review_packages_identity"

  def up
    return unless index_exists?(:layered_verification_review_packages, [ :project_id, :package_digest ],
      unique: true, name: INDEX_NAME)

    remove_index :layered_verification_review_packages, name: INDEX_NAME, algorithm: :concurrently
    add_index :layered_verification_review_packages, [ :project_id, :package_digest ], name: INDEX_NAME,
      algorithm: :concurrently
  end

  def down
    return unless index_exists?(:layered_verification_review_packages, [ :project_id, :package_digest ], name: INDEX_NAME)

    remove_index :layered_verification_review_packages, name: INDEX_NAME, algorithm: :concurrently
    add_index :layered_verification_review_packages, [ :project_id, :package_digest ], unique: true, name: INDEX_NAME,
      algorithm: :concurrently
  end
end
