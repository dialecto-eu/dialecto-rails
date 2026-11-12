class User < ApplicationRecord
  def label
    I18n.t(:title, scope: [:users, :index])
  end

  def section_label
    I18n.t(:title, scope: [:admin, Current.section])
  end
end
