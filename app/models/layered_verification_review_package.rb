# frozen_string_literal: true

require "digest"

class LayeredVerificationReviewPackage < ApplicationRecord
  # @spec LAYERED-VERIFY-023
  class ImmutablePackageError < StandardError; end

  DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

  belongs_to :project
  belongs_to :agent_run, inverse_of: :review_packages
  has_many :approvals, class_name: "LayeredVerificationReviewApproval",
    foreign_key: :package_id, dependent: :restrict_with_exception, inverse_of: :package

  before_update :prevent_mutation!
  before_destroy :prevent_mutation!

  validates :package_digest, presence: true, format: { with: DIGEST_PATTERN }
  validates :revision_number, numericality: { only_integer: true, greater_than: 0 }
  validate :agent_run_belongs_to_same_project

  # One reproducible identity over the bound inputs. A content digest
  # identifies its inputs; it never establishes semantic completeness.
  def self.digest_for(bound_inputs)
    Digest::SHA256.hexdigest(canonical_json(bound_inputs))
  end

  def self.canonical_json(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.to_h { |key| [ key, canonical_json(value[key]) ] }.to_json
    when Array
      value.map { |item| canonical_json(item) }.to_json
    else
      value.to_json
    end
  end

  def current?
    lineage.where("revision_number > ?", revision_number).none?
  end

  def lineage
    self.class.where(agent_run:)
  end

  def current_revision
    lineage.order(:revision_number).last
  end

  def superseded_by
    lineage.where("revision_number > ?", revision_number).order(:revision_number).first
  end

  def reviewed_evidence_matches?(other)
    bound_inputs.except("approval_ids") == other.bound_inputs.except("approval_ids")
  end

  private

  def agent_run_belongs_to_same_project
    return if agent_run.project_id == project_id

    errors.add(:agent_run, "must belong to the same project")
  end

  def prevent_mutation!
    raise ImmutablePackageError, "review packages are append-only"
  end
end
