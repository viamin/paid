# frozen_string_literal: true

# Corrects the +provisioning_intents+ table comment. The
# 20260814072312_create_provisioning_intents migration originally cited
# RDR-058 ("Execution Authority, Network Policy, and Isolation"), but the
# provisioning-intent ledger and provider ownership-tag work is owned by
# RDR-060 ("External Execution Resource Ledger"). This migration rewrites
# the table comment on existing databases so +db/schema.rb+ dumps the
# correct reference; fresh databases pick up the corrected comment from
# the original migration.
class CorrectProvisioningIntentsTableComment < ActiveRecord::Migration[8.1]
  CORRECT_TABLE_COMMENT = "Execution-resource provisioning-intent ledger rows recording runner intent before provider create calls so orphaned resources remain reconcileable (RDR-060).".freeze
  LEGACY_TABLE_COMMENT = "Execution-resource provisioning-intent ledger rows recording runner intent before provider create calls so orphaned resources remain reconcileable (RDR-058).".freeze

  def up
    return unless table_exists?(:provisioning_intents)

    change_table_comment :provisioning_intents, CORRECT_TABLE_COMMENT
  end

  def down
    return unless table_exists?(:provisioning_intents)

    change_table_comment :provisioning_intents, LEGACY_TABLE_COMMENT
  end
end
