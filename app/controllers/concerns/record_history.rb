module RecordHistory
  extend ActiveSupport::Concern

  private

  def load_record_history(record)
    @notes_page = [ params[:notes_page].to_i, 1 ].max
    @events_page = [ params[:events_page].to_i, 1 ].max
    @notes = record.notes.order(created_at: :desc, id: :desc).offset((@notes_page - 1) * 50).limit(51).includes(:author).to_a
    @events = record.activity_events.newest_first.offset((@events_page - 1) * 100).limit(101).to_a
    @older_notes = @notes.size > 50
    @older_events = @events.size > 100
    @notes = @notes.first(50)
    @events = @events.first(100)
  end
end
