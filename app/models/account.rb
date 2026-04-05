# frozen_string_literal: true

class Account < ApplicationRecord
  MAX_SLUG_GENERATION_ATTEMPTS = 10

  has_many :users, dependent: :destroy
  has_many :account_memberships, dependent: :destroy
  has_many :members, through: :account_memberships, source: :user
  has_many :projects, dependent: :destroy
  has_many :github_tokens, dependent: :destroy
  has_many :integration_credentials, dependent: :destroy
  has_many :linear_tokens, dependent: :destroy
  has_many :prompts, -> { where(project_id: nil) }, dependent: :destroy
  has_many :all_prompts, class_name: "Prompt"
  has_many :style_guides, -> { where(project_id: nil) }, dependent: :destroy
  has_many :mcp_server_definitions, dependent: :destroy
  has_many :pre_commit_requirements, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "can only contain lowercase letters, numbers, and hyphens" }
  validates :default_max_tokens_per_run,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 2_147_483_647 }

  before_validation :generate_slug, on: :create

  def save(**options)
    super
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?("slug")

    regenerate_slug_and_retry
  end

  def save!(**options)
    super
  rescue ActiveRecord::RecordNotUnique => e
    raise unless e.message.include?("slug")

    regenerate_slug_and_retry!
  end

  # Returns the fallback owner for this account — the first owner by ID,
  # or the first user by ID if no owner membership exists. Used for
  # orphaned-project ownership resolution.
  def fallback_owner
    account_memberships.where(role: :owner).order(:id).first&.user ||
      users.order(:id).first
  end

  # Returns just the fallback owner's ID without loading the User record.
  def fallback_owner_id
    account_memberships.where(role: :owner).order(:id).pick(:user_id) ||
      users.order(:id).pick(:id)
  end

  private

  def generate_slug
    return if slug.present?
    return if name.blank?

    base_slug = name.parameterize
    self.slug = base_slug

    counter = 1
    while self.class.exists?(slug: slug)
      self.slug = "#{base_slug}-#{counter}"
      counter += 1
    end
  end

  def regenerate_slug_and_retry(attempt: 1)
    raise ActiveRecord::RecordNotUnique, "Could not generate unique slug" if attempt > MAX_SLUG_GENERATION_ATTEMPTS

    self.slug = "#{slug_base}-#{SecureRandom.hex(4)}"
    save || regenerate_slug_and_retry(attempt: attempt + 1)
  end

  def regenerate_slug_and_retry!(attempt: 1)
    raise ActiveRecord::RecordNotUnique, "Could not generate unique slug" if attempt > MAX_SLUG_GENERATION_ATTEMPTS

    self.slug = "#{slug_base}-#{SecureRandom.hex(4)}"
    save!
  rescue ActiveRecord::RecordNotUnique
    regenerate_slug_and_retry!(attempt: attempt + 1)
  end

  def slug_base
    slug&.sub(/-[a-f0-9]{8}$/, "")&.sub(/-\d+$/, "") || name&.parameterize
  end
end
