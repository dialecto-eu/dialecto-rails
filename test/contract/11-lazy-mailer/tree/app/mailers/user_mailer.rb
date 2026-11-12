class UserMailer < ApplicationMailer
  def welcome(user)
    @greeting = t(".greeting")
    mail(to: user.email)
  end
end
