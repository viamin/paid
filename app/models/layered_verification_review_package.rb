# frozen_string_literal: true

require "digest"

class LayeredVerificationReviewPackage < ApplicationRecord
  # @spec LAYERED-VERIFY-023
  belongs_to :project
  belongs_to :approved_by, class_name: "User", optional: true

  validates :package_digest, presence: true
  validates :revision, numericality: { greater_than: 0, only_integer: true }
  validates :package_digest, uniqueness: { scope: %i[project_id revision] }

  def self.create_for!(project:, bound_inputs:)
    canonical_inputs = bound_inputs.deep_stringify_keys
    digest = Digest::SHA256.hexdigest(canonical_inputs.to_json)
    revision = where(project:).maximum(:revision).to_i + 1
    create!(project:, package_digest: digest, revision:, bound_inputs: canonical_inputs)
  end

  def approve!(user:)
    update!(approved_at: Time.current, approved_by: user)
  end
end
