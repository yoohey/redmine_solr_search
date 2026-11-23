# Checks that the loaded ja-basic data looks as intended. Run after seeding:  seed/verify.sh ja-basic
# Prints the figures for a human to read; lines starting with "NG" are real problems.
Rails.logger.level = :warn

def check(label, ok)
  puts "#{ok ? 'OK' : 'NG'}  #{label}"
end

today = Date.current
issues = Issue.count
puts "issues #{issues} (private #{Issue.where(is_private: true).count}), journals #{Journal.count}, " \
     "attachments #{Attachment.count}, relations #{IssueRelation.count}"
puts "statuses: #{Issue.group(:status_id).count.transform_keys { |id| IssueStatus.find(id).name }}"

puts '-- versions'
Version.order(:project_id, :effective_date).each do |v|
  puts "   #{v.project.identifier.ljust(16)} #{v.name.ljust(24)} #{v.effective_date} #{v.status}"
end
puts '-- plan tree (search-platform M2)'
Issue.find_by!(subject: 'M2 Redmineデータの検索').self_and_descendants.sort_by(&:lft).each do |i|
  puts "   #{'  ' * i.ancestors.count}##{i.id} #{i.subject} #{i.start_date}..#{i.due_date} " \
       "#{i.status.name} #{i.done_ratio}% #{i.estimated_hours}h"
end

puts "-- dates: with due #{Issue.where.not(due_date: nil).count}, open & overdue #{Issue.open.where('due_date < ?', today).count}, " \
     "due within 7 days #{Issue.open.where(due_date: today..today + 7).count}"
len = Issue.pluck(:description).map { |d| d.to_s.size }.sort
puts "-- description length: p25 #{len[len.size / 4]} median #{len[len.size / 2]} p90 #{len[len.size * 9 / 10]} max #{len.last}"
per_issue = Issue.left_joins(:journals).group('issues.id').count('journals.id').values.tally.sort.to_h
puts "-- journals per issue: #{per_issue}"
puts "-- attachments by extension: #{Attachment.pluck(:filename).map { |f| File.extname(f) }.tally.sort_by { |_, n| -n }.to_h}"

check 'issues are about 3,000', (2900..3100).cover?(issues)
check 'no issue kept the seeding time as created_on', Issue.where('created_on > ?', 1.hour.ago).none?
outside = Journal.joins('JOIN issues ON issues.id = journals.journalized_id')
                 .where("journals.journalized_type = 'Issue' AND (journals.created_on < issues.created_on OR journals.created_on > issues.updated_on)")
check 'every journal lies between its issue\'s created_on and updated_on', outside.none?
check 'some notes were edited later (journals.updated_on > created_on)', Journal.where('updated_on > created_on').exists?
secret = Attachment.where("filename LIKE '社外秘%'")
check 'the 社外秘 attachment exists', secret.exists?
check 'the 社外秘 attachment is only on private issues',
      secret.all? { |a| a.container_type == 'Issue' && a.container.is_private? }
check 'every private issue contains 社外秘', Issue.where(is_private: true).all? { |i| i.subject.include?('社外秘') }
planned = Issue.where.not(parent_id: nil).where.not(start_date: nil)
check 'Gantt: some planned tasks are done, some in progress, some not started yet',
      planned.where('due_date < ?', today).exists? && planned.where('start_date <= ? AND due_date >= ?', today, today).exists? &&
      planned.where('start_date > ?', today).exists?
check 'private notes are written only by users allowed to',
      Journal.where(private_notes: true).includes(:user, issue: :project).all? { |j| j.user.allowed_to?(:set_notes_private, j.issue.project) }
