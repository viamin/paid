# frozen_string_literal: true

class ExternalConnectorEvent < ApplicationRecord
  STATUSES = %w[pending processed failed].freeze

  belongs_to :project
  belongs_to :account

  validates :connector_key, presence: true, inclusion: { in: Interop::Catalog.connector_keys }
  validates :event_type, presence: true
  validates :external_event_id, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :external_event_id, uniqueness: { scope: :project_id, message: "has already been ingested for this project" }
  validate :payload_is_object
  validate :normalized_data_is_object

  scope :pending, -> { where(status: "pending") }
  scope :processed, -> { where(status: "processed") }
  scope :failed, -> { where(status: "failed") }
  scope :by_connector, ->(key) { where(connector_key: key) }
  scope :by_event_type, ->(type) { where(event_type: type) }
  scope :recent, -> { order(created_at: :desc) }

  before_validation :set_account_from_project

  def mark_processed!
    update!(status: "processed", processed_at: Time.current)
  end

  def mark_failed!(message: nil)
    attrs = { status: "failed", processed_at: Time.current }
    attrs[:normalized_data] = (normalized_data || {}).merge("error" => message) if message.present?
    update!(**attrs)
  end

  private

  def set_account_from_project
    self.account ||= project&.account
  end

  def payload_is_object
    return if payload.nil? || payload.is_a?(Hash)

    errors.add(:payload, "must be a JSON object")
  end

  def normalized_data_is_object
    return if normalized_data.nil? || normalized_data.is_a?(Hash)

    errors.add(:normalized_data, "must be a JSON object")
  end
end
