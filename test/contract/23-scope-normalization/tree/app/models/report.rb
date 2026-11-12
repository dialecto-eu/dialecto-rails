class Report
  def labels
    [
      I18n.t(:title, scope: "users."),
      I18n.t(:name, scope: :"users.admin"),
      I18n.t(:email, scope: [:users, "admin."])
    ]
  end
end
