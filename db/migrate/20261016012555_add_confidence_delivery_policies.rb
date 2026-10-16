# frozen_string_literal: true

class AddConfidenceDeliveryPolicies < ActiveRecord::Migration[8.1]
  def up
    add_project_policy_selection
    add_feature_policy_snapshot
  end

  def down
    remove_column :feature_intents, :delivery_policy if column_exists?(:feature_intents, :delivery_policy)
    remove_column :projects, :confidence_delivery_enrollment_enabled if column_exists?(:projects, :confidence_delivery_enrollment_enabled)
    remove_column :projects, :new_feature_delivery_policy if column_exists?(:projects, :new_feature_delivery_policy)
  end

  private

  def add_project_policy_selection
    unless column_exists?(:projects, :new_feature_delivery_policy)
      add_column :projects, :new_feature_delivery_policy, :string, null: false, default: "approval_gated",
        comment: "Selected delivery policy for newly enrolled features; existing feature snapshots are unaffected."
    end

    return if column_exists?(:projects, :confidence_delivery_enrollment_enabled)

    add_column :projects, :confidence_delivery_enrollment_enabled, :boolean, null: false, default: false,
      comment: "Permits newly created features to snapshot the selected confidence-driven policy; does not release work."
  end

  def add_feature_policy_snapshot
    return if column_exists?(:feature_intents, :delivery_policy)

    add_column :feature_intents, :delivery_policy, :string, null: false, default: "approval_gated",
      comment: "Immutable delivery-policy snapshot selected when the feature was enrolled."
  end
end
