module Admin
  class UsersController < ApplicationController
    def create
      @user = User.create!(user_params)
      notify
      redirect_to admin_users_path, notice: t(".created")
    end

    private

    def notify
      UserMailer.created(@user, t(".created")).deliver_later
    end
  end
end
