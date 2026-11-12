class UsersController < ApplicationController
  def update
    @user.update!(user_params)
    redirect_to @user, notice: t('users.saved')
  end

  def destroy
    @user.destroy!
    flash[:notice] = t(
      "users.deleted",
      name: @user.name
    )
    redirect_to users_path
  end
end
