require 'redcloth'

class ContentPage < ActiveRecord::Base
  validates :name, presence: true
  validates :name, uniqueness: true

  belongs_to :permission

  attr_accessor :content_html

  def url
    "/#{name}"
  end

  def markup_style
    @markup_style = MarkupStyle.find markup_style_id if !@markup_style && markup_style_id && markup_style_id > 0
  end

  before_save :setup_save
  def setup_save
    self.content_cache = markup_content
  end

  def content_html
    if content_cache.present?
      content_cache.html_safe
    else
      markup_content.html_safe
    end
  end

  protected

  def markup_content
    markup = markup_style
    if markup && markup.name
      if markup.name == 'Textile'
        RedCloth.new(content).to_html(:textile)
      elsif markup.name == 'Markdown'
        RedCloth.new(content).to_html(:markdown)
      else
        content
      end
    else
      content
    end
  end
end
