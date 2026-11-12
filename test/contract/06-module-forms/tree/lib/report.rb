module Report
  def self.labels
    [
      I18n.t("report.title"),
      I18n.translate("report.subtitle"),
      I18n.t!("report.total"),
      I18n.translate!("report.footer"),
      I18n.exists?("report.note")
    ]
  end
end
