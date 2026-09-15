class NotesController < ApplicationController
  def create
    @notable = find_notable
    return render_not_found unless @notable
    if @notable.is_a?(Lead) && @notable.converted?
      return redirect_to @notable, alert: "Converted leads stay read-only."
    end

    @note = @notable.notes.build(note_params)
    @note.author = current_user
    if @note.save
      redirect_to @notable, notice: "Note saved."
    else
      redirect_to @notable, alert: @note.errors.full_messages.to_sentence
    end
  end

  def destroy
    @note = Note.find(params[:id])
    notable = @note.notable
    @note.destroy!
    redirect_to notable, notice: "Note removed.", status: :see_other
  end

  private

  def find_notable
    if params[:client_id]
      Client.find_by(id: params[:client_id])
    elsif params[:organization_id]
      Organization.find_by(id: params[:organization_id])
    elsif params[:lead_id]
      Lead.find_by(id: params[:lead_id])
    end
  end

  def note_params
    params.require(:note).permit(:body)
  end

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
