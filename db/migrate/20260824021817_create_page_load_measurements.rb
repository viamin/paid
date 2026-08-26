# frozen_string_literal: true

class CreatePageLoadMeasurements < ActiveRecord::Migration[8.1]
  def up
    create_table :page_load_measurements, comment: "Page load timings captured while screenshotting a pull request's changed routes. One row per route per capture; the durable source of truth behind the per-project page-load ledger export." do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent_run, null: true, foreign_key: { on_delete: :nullify }, comment: "The capture run that produced the measurement; nullified when the run is pruned."
      t.integer :pull_request_number, null: false
      t.string :commit_sha, limit: 64, null: false
      t.string :route_name, limit: 255, null: false, comment: "Screenshot route name; the series key for trend and regression comparison."
      t.string :route_path, limit: 2048, comment: "Path the route resolved to. A change here disqualifies comparison against an earlier capture."
      t.integer :http_status, comment: "Status of the measured navigation. A change here disqualifies comparison."
      t.string :source, limit: 40, null: false, default: "screenshot_capture", comment: "Which pipeline measured this: screenshot_capture today."
      t.integer :ttfb_ms, comment: "Median time to first byte, milliseconds from navigation start."
      t.integer :dcl_ms, comment: "Median DOMContentLoaded, milliseconds from navigation start."
      t.integer :load_ms, comment: "Median load event end, milliseconds from navigation start."
      t.integer :fcp_ms, comment: "Median first contentful paint; null when the page produced no qualifying paint."
      t.integer :lcp_ms, comment: "Median largest contentful paint; null when no LCP entry was observed."
      t.jsonb :samples, null: false, default: {}, comment: "Per-metric raw sample values with min/max, so measurement noise stays inspectable."
      t.integer :sample_count, null: false, default: 1
      t.integer :viewport_width
      t.integer :viewport_height
      t.datetime :captured_at, null: false

      t.timestamps null: false
    end

    add_index :page_load_measurements,
      [ :project_id, :pull_request_number, :commit_sha, :route_name ],
      unique: true, name: "idx_page_load_measurements_capture_route"
    add_index :page_load_measurements,
      [ :project_id, :route_name, :captured_at ],
      order: { captured_at: :desc }, name: "idx_page_load_measurements_route_recent"
    add_index :page_load_measurements,
      [ :project_id, :pull_request_number, :route_name ],
      name: "idx_page_load_measurements_pr_route"
    add_index :page_load_measurements, :captured_at, name: "idx_page_load_measurements_captured_at"

    add_check_constraint :page_load_measurements,
      "sample_count >= 1", name: "chk_page_load_measurements_sample_count"
    add_check_constraint :page_load_measurements,
      "source IN ('screenshot_capture')", name: "chk_page_load_measurements_source_valid"

    safety_assured do
      execute <<~SQL
        ALTER TABLE page_load_measurements ENABLE ROW LEVEL SECURITY;
        ALTER TABLE page_load_measurements FORCE ROW LEVEL SECURITY;
        CREATE POLICY tenant_isolation ON page_load_measurements
          AS PERMISSIVE FOR ALL
          USING (paid_tenant_bypass() OR (page_load_measurements.account_id = paid_current_account_id()))
          WITH CHECK (paid_tenant_bypass() OR (page_load_measurements.account_id = paid_current_account_id()));
      SQL
    end
  end

  def down
    safety_assured { execute "DROP POLICY IF EXISTS tenant_isolation ON page_load_measurements" }
    safety_assured { execute "ALTER TABLE page_load_measurements NO FORCE ROW LEVEL SECURITY" }
    safety_assured { execute "ALTER TABLE page_load_measurements DISABLE ROW LEVEL SECURITY" }

    drop_table :page_load_measurements
  end
end
