# frozen_string_literal: true

# A page's load timings from one screenshot capture of one route.
#
# Rows are the durable record behind the per-project page-load ledger export
# and the baseline for before/after regression comparison. Append-only in
# spirit — a re-capture at the same commit replaces its row rather than adding
# a second one, so a retried run never becomes its own baseline.
#
# @spec PAGE-LOAD-LEDGER-001, PAGE-LOAD-LEDGER-002
class PageLoadMeasurement < ApplicationRecord
  METRICS = %w[ttfb_ms dcl_ms load_ms fcp_ms lcp_ms].freeze
  FALLBACK_METRIC = "load_ms"
  SOURCES = %w[screenshot_capture].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :agent_run, optional: true

  validates :pull_request_number, :commit_sha, :route_name, :captured_at, presence: true
  validates :sample_count, numericality: { greater_than_or_equal_to: 1 }
  validates :source, inclusion: { in: SOURCES }

  scope :for_route, ->(route_name) { where(route_name: route_name) }
  scope :for_pull_request, ->(number) { where(pull_request_number: number) }
  scope :recent_first, -> { order(captured_at: :desc, id: :desc) }

  # @spec PAGE-LOAD-LEDGER-004
  def self.prune_older_than(cutoff)
    where(captured_at: ...cutoff).delete_all
  end

  # The most recent measurement of the same route on the same pull request from
  # an earlier commit — the "before" side of the comparison the screenshot
  # comment already shows.
  def baseline
    self.class
      .where(project_id: project_id, pull_request_number: pull_request_number, route_name: route_name)
      .where.not(commit_sha: commit_sha)
      .recent_first
      .first
  end

  def metric(name)
    self[name] if METRICS.include?(name.to_s)
  end

  def viewport
    [ viewport_width, viewport_height ]
  end
end
