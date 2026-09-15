module TaggedRecord
  extend ActiveSupport::Concern

  included do
    validate :validate_pending_tags
    after_save :assign_pending_tags
  end

  def tag_list
    return @pending_tag_list unless @pending_tag_list.nil?

    tags.map(&:name).join(", ")
  end

  def tag_list=(value)
    @pending_tag_list = value.to_s.split(",").map(&:strip).reject(&:blank?).map(&:downcase).uniq.first(20).join(", ")
  end

  private

  def validate_pending_tags
    return if @pending_tag_list.nil?

    @pending_tag_list.split(", ").each do |name|
      tag = Tag.find_by(name: name) || Tag.new(name: name)
      tag.valid?
      tag.errors[:name].each { |message| errors.add(:tag_list, message) }
    end
  end

  def assign_pending_tags
    return if @pending_tag_list.nil?

    self.tags = @pending_tag_list.split(", ").map { |name| Tag.find_or_create_by!(name: name) }
    @pending_tag_list = nil
  end
end
