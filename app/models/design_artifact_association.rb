# frozen_string_literal: true

# Immutable structural evidence that connected a repository design artifact to
# already synchronized work. It records a local association; it never edits the
# source artifact or authorizes work on the issue.
# @spec DESIGN-RECONCILIATION-001
class DesignArtifactAssociation < ApplicationRecord
  belongs_to :account
  belongs_to :project

  validates :artifact_path, :artifact_revision, :issue_identity, :provenance, presence: true
  validates :issue_identity, uniqueness: { scope: [ :project_id, :artifact_path, :artifact_revision ] }
end
