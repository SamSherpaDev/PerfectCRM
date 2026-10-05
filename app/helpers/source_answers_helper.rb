module SourceAnswersHelper
  def source_answer_options
    [ [ "Not asked yet", "not_asked" ] ] + SourceHistory::ANSWERS.map { |code, label| [ label, code ] } + [ [ "Declined to answer", "declined" ] ]
  end
end
