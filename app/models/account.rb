# frozen_string_literal: true

class Account < ApplicationRecord
  resourcify

  MAX_SLUG_GENERATION_ATTEMPTS = 10

  has_many :users, dependent: :destroy
  has_many :github_tokens, dependent: :destroy
  has_many :projects, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9-]+\z/, message: "can only contain lowercase letters, numbers, and hyphens" }

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
