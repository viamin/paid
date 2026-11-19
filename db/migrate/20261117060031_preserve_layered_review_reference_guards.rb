# frozen_string_literal: true

require Rails.root.join("db/migrate/20261116190000_create_layered_verification_review_packages")

# @spec LAYERED-VERIFY-023 POSTGRESQL-PERSISTENCE-006
class PreserveLayeredReviewReferenceGuards < ActiveRecord::Migration[8.1]
  def up
    CreateLayeredVerificationReviewPackages.new.send(:remove_project_reference_enforcement)
    create_function :enforce_layered_review_package_references, version: 1
    create_function :enforce_layered_review_approval_actor, version: 1
    replace_trigger :enforce_layered_review_package_references, on: :layered_verification_review_packages
    replace_trigger :enforce_layered_review_approval_actor, on: :layered_verification_review_approvals
  end

  def down
    # A corrective rollback retains the current reference guards.
  end

  private

  def replace_trigger(name, on:)
    exists = select_value(<<~SQL)
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = #{connection.quote("public.#{on}")}::regclass
        AND tgname = #{connection.quote(name.to_s)}
    SQL
    drop_trigger(name, on:) if exists
    create_trigger(name, version: 1, on:)
  end
end
