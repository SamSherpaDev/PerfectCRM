class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "info@sherpaholidays.com")
  layout "mailer"
end
