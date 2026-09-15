module TasksHelper
  def suggested_task_message(subject)
    return if params[:task].blank? || params[:template].blank?

    task = subject.tasks.includes(:template).find_by(id: params[:task], template_id: params[:template])
    template = task&.template
    return unless template

    context = { first_name: subject.name.split.first, full_name: subject.name }
    {
      subject: TemplateRenderer.render(template.subject, context),
      body: TemplateRenderer.render(template.body, context),
      email: subject.is_a?(Organization) ? subject.email : subject.display_email
    }
  end
end
