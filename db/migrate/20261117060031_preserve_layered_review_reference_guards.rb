# frozen_string_literal: true

require Rails.root.join("db/migrate/20261116190000_create_layered_verification_review_packages")

# @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
class PreserveLayeredReviewReferenceGuards < ActiveRecord::Migration[8.1]
  def up
    CreateLayeredVerificationReviewPackages.new.send(:remove_project_reference_enforcement)
    create_function :enforce_layered_review_package_references, version: 1
    create_function :enforce_layered_review_approval_actor, version: 1
    create_trigger :enforce_layered_review_package_references, version: 1, on: :layered_verification_review_packages
    create_trigger :enforce_layered_review_approval_actor, version: 1, on: :layered_verification_review_approvals
  end

  def down
    drop_trigger :enforce_layered_review_approval_actor, on: :layered_verification_review_approvals
    drop_trigger :enforce_layered_review_package_references, on: :layered_verification_review_packages
    drop_function :enforce_layered_review_approval_actor
    drop_function :enforce_layered_review_package_references
    CreateLayeredVerificationReviewPackages.new.send(:enforce_project_references)
  end
end
