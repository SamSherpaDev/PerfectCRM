# The automatic "Your trip match" email as the visitor receives it
# (README.md, "Leads"), so the owner can read the wording before switching
# it on in Settings > Automations. Shows the sample quiz match with or without
# a call request (?call=0).
class TripQuizEmailsController < ApplicationController
  def show
    @settings = Setting.current
    @call_requested = params[:call] != "0"
    @content = TripQuizEmail.content(first_name: "Alex", quiz: TripQuizEmail::SAMPLE_QUIZ,
      call_request: (TripQuizEmail::SAMPLE_CALL_REQUEST if @call_requested))
  end
end
