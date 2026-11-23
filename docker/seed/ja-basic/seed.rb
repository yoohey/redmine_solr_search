# Dataset ja-basic (README.md next to this file). Run through seed/run.sh ja-basic (rails runner, production env).
# Builds users / projects / memberships so that "visible vs not visible" differs per user, then generates about
# 3,000 Japanese issues with a realistic mix of statuses, history, dates and lengths, a planned schedule (versions and
# parent/child tasks with dates, for the Gantt chart), wiki pages, documents and attachments (attachments/).
# Random but repeatable (fixed seed): the content and the ids are the same whatever day it runs, only the dates move
# with "today" (SEED_TODAY=YYYY-MM-DD pins it). Anything whose amount depends on the date (the planned tasks) is
# created last so that it can't shift the random sequence or the ids of the rest. Refuses to run twice.
#
#   user       role                                     sees
#   tanaka     Manager in all projects                  everything, incl. private issues/notes
#   suzuki     Developer in search-platform, dept-docs  public issues + own private ones there
#   yamada     Developer in dept-docs                   dept-docs + general
#   sato       Reporter in search-platform              search-platform + general
#   takahashi  (no membership)                          only the public project "general"
#
# Private issues always contain the word 社外秘, and only they get the 社外秘 attachment (fictional station names),
# so a search for either quickly shows permission leaks later.

require 'yaml'
require 'zlib'

ActionMailer::Base.perform_deliveries = false
srand(42)

PASSWORD = ENV.fetch('SEED_PASSWORD', 'password') # dev only: the stack is reachable from this Mac only
ISSUES_PER_PROJECT = { 'search-platform' => 1180, 'dept-docs' => 1180, 'general' => 600 }.freeze # + planned tasks
ATTACHMENTS_DIR = File.expand_path('attachments', __dir__)

abort 'Sample data already exists (project "search-platform"). Reset the environment first (docker compose down -v in docker/, see docker/seed/README.md).' if Project.exists?(identifier: 'search-platform')

admin = User.find_by!(login: 'admin')
User.current = admin

# Same password as everyone else and no forced change at first login, so the stack is usable right after seeding
admin.password = admin.password_confirmation = PASSWORD
admin.must_change_passwd = false
admin.save!

Setting.default_language = 'ja'
Setting.user_format = 'lastname_firstname'
Setting.text_formatting = 'common_mark'
Setting.notified_events = []

NOW = ENV['SEED_TODAY'] ? Time.zone.parse("#{ENV['SEED_TODAY']} 12:00") : Time.current
TODAY = NOW.to_date

# ---- users ---------------------------------------------------------------------------------------------------
USERS = {
  'tanaka'    => %w[田中 太郎],
  'suzuki'    => %w[鈴木 花子],
  'yamada'    => %w[山田 次郎],
  'sato'      => %w[佐藤 一郎],
  'takahashi' => %w[高橋 美咲]
}.freeze

users = USERS.to_h do |login, (last, first)|
  u = User.new(firstname: first, lastname: last, mail: "#{login}@example.test", language: 'ja')
  u.login = login
  u.password = u.password_confirmation = PASSWORD
  u.status = User::STATUS_ACTIVE
  u.save!
  [login, u]
end

# ---- projects & memberships ------------------------------------------------------------------------------------
manager, developer, reporter = Role.givable.sorted.to_a # default data order: Manager, Developer, Reporter
MODULES = %w[issue_tracking wiki documents gantt calendar].freeze

def create_project(identifier, name, description, is_public)
  p = Project.new(name: name, identifier: identifier, description: description, is_public: is_public)
  p.enabled_module_names = MODULES
  p.trackers = Tracker.sorted.to_a
  p.save!
  p
end

projects = {
  'search-platform' => create_project('search-platform', '全文検索基盤', '部門ドキュメントを横断検索する基盤の開発', false),
  'dept-docs'       => create_project('dept-docs', '部門ドキュメント整備', '共有フォルダの文書を棚卸しして整理する', false),
  'general'         => create_project('general', '全社お知らせ', '全社向けのお知らせと問い合わせ', true)
}

def add_member(project, user, role)
  Member.create!(project: project, principal: user, roles: [role])
end

projects.each_value { |p| add_member(p, users['tanaka'], manager) }
add_member(projects['search-platform'], users['suzuki'], developer)
add_member(projects['dept-docs'],       users['suzuki'], developer)
add_member(projects['dept-docs'],       users['yamada'], developer)
add_member(projects['search-platform'], users['sato'],   reporter)

CATEGORIES = {
  'search-platform' => %w[インデックス 検索画面 クローラー 運用 インフラ],
  'dept-docs'       => %w[規程 棚卸し フォルダ整理 教育],
  'general'         => %w[総務 人事 情報システム 施設]
}.freeze

categories = CATEGORIES.to_h do |identifier, names|
  [identifier, names.map { |name| IssueCategory.create!(project: projects[identifier], name: name) }]
end

# ---- statuses (default data, ja: 新規 進行中 解決 フィードバック 終了 却下) -----------------------------------------
ST_NEW, ST_PROGRESS, ST_RESOLVED, ST_FEEDBACK, ST_CLOSED, ST_REJECTED = IssueStatus.sorted.to_a
TRACKERS = Tracker.sorted.to_a # バグ, 機能, サポート
PRIORITIES = IssuePriority.active.sorted.to_a # 低め, 通常, 高め, 急いで, 今すぐ

def weighted(weights)
  r = rand * weights.values.sum
  weights.each { |key, w| return key if (r -= w) < 0 }
  weights.keys.last
end

# Old issues are mostly finished, recent ones mostly still open
def pick_status(age_days)
  if age_days > 180
    weighted({ ST_NEW => 2, ST_PROGRESS => 4, ST_RESOLVED => 6, ST_FEEDBACK => 3, ST_CLOSED => 70, ST_REJECTED => 15 })
  elsif age_days > 45
    weighted({ ST_NEW => 8, ST_PROGRESS => 18, ST_RESOLVED => 18, ST_FEEDBACK => 10, ST_CLOSED => 38, ST_REJECTED => 8 })
  else
    weighted({ ST_NEW => 45, ST_PROGRESS => 28, ST_RESOLVED => 10, ST_FEEDBACK => 10, ST_CLOSED => 5, ST_REJECTED => 2 })
  end
end

# The statuses an issue went through after 新規 to reach its current status (one journal per step)
def status_path(target)
  detour = [ST_PROGRESS, ST_FEEDBACK, ST_PROGRESS]
  case target
  when ST_NEW      then []
  when ST_PROGRESS then rand < 0.2 ? detour : [ST_PROGRESS]
  when ST_FEEDBACK then [ST_PROGRESS, ST_FEEDBACK]
  when ST_RESOLVED then (rand < 0.3 ? detour : [ST_PROGRESS]) + [ST_RESOLVED]
  when ST_CLOSED
    weighted({ [ST_PROGRESS, ST_CLOSED] => 25, [ST_PROGRESS, ST_RESOLVED, ST_CLOSED] => 55,
               [ST_PROGRESS, ST_RESOLVED, ST_PROGRESS, ST_RESOLVED, ST_CLOSED] => 20 })
  when ST_REJECTED then rand < 0.3 ? [ST_FEEDBACK, ST_REJECTED] : [ST_REJECTED]
  end
end

def done_ratio_for(status)
  case status
  when ST_NEW, ST_REJECTED       then 0
  when ST_RESOLVED, ST_CLOSED    then 100
  when ST_FEEDBACK               then rand(1..8) * 10
  else                                rand(1..9) * 10
  end
end

# ---- text generation -----------------------------------------------------------------------------------------
WORDS = {
  'search-platform' => %w[Solr インデックス スキーマ クエリ 形態素解析 Kuromoji ハイライト ページング ManifoldCF Tika
                          クローラー 監視 Prometheus Grafana nginx 認証 権限 プラグイン 再インデックス 同義語辞書
                          ファセット 分散検索 シャード レスポンス速度 ログ],
  'dept-docs'       => %w[規程 議事録 計画書 手順書 共有フォルダ 棚卸し 命名規則 保管期限 申請書 テンプレート
                          版管理 承認フロー 設計書 仕様書 報告書 ファイルサーバー アクセス権 アーカイブ 様式 教育資料],
  'general'         => %w[健康診断 避難訓練 社内システム メンテナンス 休暇 年末調整 研修 入館証 備品 在宅勤務
                          経費精算 勤怠 ネットワーク パスワード変更 複合機 会議室予約 安否確認 社内報]
}.freeze

TITLES = {
  short:  ['%{a}の件', '%{a}', '%{a}が動かない', '%{a}について', '%{b}確認'],
  normal: ['%{a}の%{b}について', '%{a}で%{b}が発生する', '【議事録】第%{n}回 %{a}定例', '%{a}の手順書を更新する',
           '%{a}と%{b}の比較検討', '%{a}の%{b}を見直したい', '%{a}に関する問い合わせ', '%{a}の不具合（%{b}関連）',
           '%{a}の計画書 第%{n}版', '%{a}の運用ルール案', '%{b}対応：%{a}の調査', '%{a}の%{b}が遅い'],
  long:   ['【至急】%{a}の%{b}において、特定の条件で%{c}が正しく処理されない件について（第%{n}報）',
           '%{a}・%{b}・%{c}の3点について、来期に向けた方針と担当の整理をお願いしたい',
           '%{a}を変更した後から%{b}の結果が以前と異なるように見える（%{c}の影響の可能性あり）']
}.freeze

SENTENCES = [
  '%{a}について、現状の課題を整理した。', '%{b}の影響範囲を確認する必要がある。', '%{a}と%{b}の関係を図にまとめた。',
  '次回までに%{a}の担当者を決める。', '%{b}は前回の打ち合わせで保留となっていた。', '%{a}の手順に抜けがあったため修正した。',
  '関係部署に%{b}の確認を依頼済み。', '%{a}の見積もりは約%{n}人日。', '%{b}のログを添付する。',
  '%{a}の設定値を変更したところ改善した。', '期限は%{n}月末を目安とする。', '%{a}の%{b}について再発防止策を検討する。',
  '%{c}との整合も確認しておく。', '%{a}は%{b}より優先度が高いと判断した。', '%{b}の件は%{c}の結果を待って再開する。'
].freeze

NOTES = [
  '確認しました。%{a}の件は対応します。', '%{b}の再現手順を追記しました。', '担当を変更します。',
  '%{a}の修正を反映しました。確認をお願いします。', '%{b}は別チケットで扱います。', '打ち合わせの結果、%{a}で進めることになりました。',
  '了解です。', '%{c}の状況はどうなっていますか？', '少し遅れていますが、%{n}日までには対応します。'
].freeze

STATUS_NOTES = {
  ST_PROGRESS => ['着手します。', '%{a}から対応を始めます。', '再開します。'],
  ST_FEEDBACK => ['%{a}について確認させてください。', '%{b}の前提が不明なため、起票者に確認中です。'],
  ST_RESOLVED => ['修正しました。確認をお願いします。', '%{a}の設定を見直して対応しました。'],
  ST_CLOSED   => ['確認しました。クローズします。', '問題ないことを確認しました。'],
  ST_REJECTED => ['仕様どおりのため却下します。', '重複のため却下します。', '%{a}の方針変更により対応不要となりました。']
}.freeze

LOG_WORDS = %w[indexer crawler search auth scheduler updater].freeze

def fill(template, words)
  a, b, c = words.sample(3)
  format(template, a: a, b: b, c: c, n: rand(1..12))
end

def paragraph(words, count)
  Array.new(count) { fill(SENTENCES.sample, words) }.join
end

def bullets(words, count)
  Array.new(count) { "- #{fill(SENTENCES.sample, words)}" }.join("\n")
end

def log_block(count)
  base = NOW - rand(30).days
  lines = Array.new(count) do |i|
    level = weighted({ 'INFO' => 6, 'WARN' => 2, 'ERROR' => 1 })
    "#{(base + i * rand(1..90)).strftime('%Y-%m-%d %H:%M:%S')} #{level.ljust(5)} [#{LOG_WORDS.sample}] " +
      %w[request\ done timeout\ after\ 30000ms retrying connection\ refused commit\ ok].sample
  end
  "```\n#{lines.join("\n")}\n```"
end

def markdown_text(words)
  <<~MD
    ## 背景

    #{paragraph(words, rand(2..4))}

    ## 対応内容

    #{bullets(words, rand(3..6))}

    ## 確認結果

    | 項目 | 結果 | 備考 |
    |---|---|---|
    #{Array.new(rand(2..5)) { "| #{words.sample} | #{%w[OK OK OK NG 保留].sample} | #{fill('%{a}を確認', words)} |" }.join("\n")}

    #{rand < 0.5 ? log_block(rand(3..8)) : paragraph(words, 2)}
  MD
end

def minutes_text(words)
  topics = words.sample(rand(7..12))
  text = +"## 日時\n\n#{rand(1..12)}月#{rand(1..28)}日 #{rand(9..17)}:00〜\n\n"
  text << "## 出席者\n\n#{USERS.values.map { |last, _| last }.sample(rand(2..5)).join('、')}\n\n## 議題\n\n"
  topics.each_with_index { |t, i| text << "#{i + 1}. #{t}について\n" }
  topics.each do |t|
    text << "\n## #{t}について\n\n#{paragraph(words, rand(6..14))}\n"
    text << "\n#{bullets(words, rand(3..8))}\n" if rand < 0.7
  end
  text << "\n## 次回までの宿題\n\n#{bullets(words, rand(2..4))}\n"
end

def incident_text(words)
  <<~MD
    ## 発生日時

    #{(NOW - rand(60).days).strftime('%Y年%-m月%-d日 %H:%M')}頃

    ## 影響範囲

    #{paragraph(words, rand(2..4))}

    ## 経緯

    #{bullets(words, rand(8..15))}

    ## 原因

    #{paragraph(words, rand(8..15))}

    ## ログ

    #{log_block(rand(20..50))}

    ## 暫定対応

    #{paragraph(words, rand(2..4))}

    ## 恒久対策

    #{bullets(words, rand(3..6))}
  MD
end

# Lengths vary a lot on purpose: one line, a few sentences, structured Markdown, a long report
def description(words)
  case weighted({ short: 20, normal: 45, markdown: 25, long: 10 })
  when :short    then fill(['タイトルの通り。', '詳細は添付を参照。', '%{a}の件、対応をお願いします。', '至急確認お願いします。'].sample, words)
  when :normal   then paragraph(words, rand(2..6))
  when :markdown then markdown_text(words)
  else                rand < 0.5 ? minutes_text(words) : incident_text(words)
  end
end

def subject(words)
  fill(TITLES[weighted({ short: 15, normal: 75, long: 10 })].sample, words)
end

def note(words)
  case weighted({ short: 60, normal: 30, long: 10 })
  when :short  then fill(NOTES.sample, words)
  when :normal then paragraph(words, rand(2..4))
  else              "#{paragraph(words, rand(3..5))}\n\n#{bullets(words, rand(3..6))}\n\n#{paragraph(words, rand(1..3))}"
  end
end

# Most issues have few notes, a few have many
def note_count
  weighted({ 0 => 30, 1 => 20, 2 => 15, 3 => 12, rand(4..8) => 15, rand(10..20) => 8 })
end

# ---- dates -------------------------------------------------------------------------------------------------------
def next_working_day(date)
  date += 1 while date.saturday? || date.sunday?
  date
end

# The day a task of `days` working days starting on `start` ends
def add_working_days(start, days)
  (days - 1).times.reduce(start) { |d, _| next_working_day(d + 1) }
end

def time_on(date)
  [date.in_time_zone.change(hour: rand(9..18), min: rand(60)), NOW].min
end

# ---- attachments -------------------------------------------------------------------------------------------------
LINES = YAML.safe_load_file(File.join(ATTACHMENTS_DIR, 'lines.yml')).to_h { |l| [l['id'], l['name']] }
MANIFEST = YAML.safe_load_file(File.join(ATTACHMENTS_DIR, 'manifest.yml'))
PUBLIC_FILES = MANIFEST.reject { |m| m['secret'] }.freeze
SECRET_FILES = MANIFEST.select { |m| m['secret'] }.freeze

def attach(container, entry, author, time)
  path = File.join(ATTACHMENTS_DIR, 'files', entry['file'])
  File.open(path, 'rb') do |f|
    a = Attachment.new(file: f, author: author)
    a.filename = entry['file']
    a.content_type = Redmine::MimeType.of(entry['file']) || 'application/octet-stream'
    a.description = format(['最新版', '%{line}の駅一覧', '参考資料', '差し替え版'].sample, line: LINES[entry['line']]) if rand < 0.4
    a.container = container
    a.save!
    a.update_columns(created_on: time)
    a
  end
end

def pick_files(private_container)
  files = PUBLIC_FILES.sample(weighted({ 1 => 70, 2 => 20, 3 => 10 }))
  private_container && rand < 0.5 ? SECRET_FILES + files.first(1) : files
end

# Journals bump the issue's lock_version, so a loaded Issue is stale by then: write the timestamps with SQL
def set_times(issue, **columns)
  Issue.where(id: issue.id).update_all(columns)
end

# ---- journals ------------------------------------------------------------------------------------------------
def add_journal(issue, user, time, notes: '', private_notes: false, details: [])
  j = Journal.new(journalized: issue, user: user, notes: notes, private_notes: private_notes)
  details.each { |d| j.details << JournalDetail.new(d) }
  j.save!
  j.update_columns(created_on: time, updated_on: time)
  # Some notes are edited later (journals.updated_on moves, which the delta crawler has to notice)
  if notes.present? && rand < 0.05
    j.update_columns(updated_on: [time + rand(1..72).hours, NOW].min, updated_by_id: user.id)
  end
  j
end

def status_detail(from, to)
  { property: 'attr', prop_key: 'status_id', old_value: from.id.to_s, value: to.id.to_s }
end

# ---- planned schedule (versions + parent/child tasks, for the Gantt chart) --------------------------------------
# [version, [[task, working days] or [task, [[subtask, days], ...]], ...]]. Tasks follow each other ("precedes").
PLANS = {
  'search-platform' => {
    start: -120,
    versions: [
      ['M1 技術検証', [['SolrCloud環境の構築', 8], ['configset共通化方式の検証', 6], ['複数コレクション検索の挙動確認', 8],
                    ['ブロックジョインの挙動確認', 6], ['日本語解析（Kuromoji・2-gram）の比較', 5], ['検証結果のまとめ', 3]]],
      ['M2 Redmineデータの検索', [['スキーマv1の設計', 6], ['差分クロールの実装', 10], ['全件照合クロールの実装', 8],
                              ['検索画面の実装', [['検索フォーム', 4], ['結果一覧とハイライト', 6], ['ページング', 3]]],
                              ['アクセス権フィルタの実装', 8], ['結合テスト', 6]]],
      ['M3 外部文書の取り込み', [['ManifoldCFの導入', 8], ['共有フォルダのクロール設定', 6], ['Tikaによる本文抽出の確認', 6],
                             ['SharePoint連携の調査', 10], ['コレクション別ラベルの管理画面', 8]]],
      ['M4 本番移行', [['本番環境の構築', 10], ['初回インデックス作成', 4], ['運用手順書の作成', 6], ['利用者説明会', 2],
                     ['本番リリース', 1]]]
    ]
  },
  'dept-docs' => {
    start: -90,
    versions: [
      ['棚卸し第1期', [['対象フォルダの洗い出し', 5], ['保管期限の確認', 8], ['不要文書の廃棄申請', 6], ['第1期の報告', 2]]],
      ['棚卸し第2期', [['命名規則の改定案作成', 6], ['フォルダ構成の再設計', 10], ['移行手順書の作成', 5],
                     ['文書の移行作業', [['規程類の移行', 5], ['議事録の移行', 5], ['設計書の移行', 5]]], ['第2期の報告', 2]]],
      ['文書管理規程の改定', [['現行規程の問題点整理', 6], ['改定案の作成', 10], ['法務レビュー', 8], ['承認・周知', 4]]]
    ]
  }
}.freeze

def plan_status(start, due)
  if due < TODAY then rand < 0.85 ? ST_CLOSED : ST_PROGRESS # a few are late
  elsif start <= TODAY then ST_PROGRESS
  else ST_NEW
  end
end

# How many random numbers a task uses depends on the date (late or not, closed or not), so each task restarts the
# sequence from its own name and draws its text first: the text is then the same whatever day the seed runs
def create_task(project, version, name, start, days, parent, members, created)
  srand(Zlib.crc32(name))
  text = paragraph(WORDS[project.identifier], rand(1..3))
  assignee = members.sample
  due = add_working_days(start, days)
  status = plan_status(start, due)
  done = if status == ST_CLOSED then 100
         elsif status == ST_NEW then 0
         elsif due < TODAY then rand(6..9) * 10
         else [((TODAY - start).to_f / (due - start + 1) * 10).floor * 10, 90].min
         end
  issue = Issue.new(project: project, tracker: TRACKERS[1], author: members.first, subject: name,
                    description: text, priority: PRIORITIES[1],
                    assigned_to: assignee, fixed_version: version, start_date: start, due_date: due,
                    estimated_hours: days * 6, done_ratio: done, parent_issue_id: parent&.id)
  issue.status = status
  issue.save!
  add_journal(issue, issue.assigned_to, time_on(start), details: [status_detail(ST_NEW, ST_PROGRESS)]) if start <= TODAY
  if status == ST_CLOSED
    closed = time_on(due)
    add_journal(issue, issue.assigned_to, closed, notes: '完了しました。', details: [status_detail(ST_PROGRESS, ST_CLOSED)])
  end
  updated = if status == ST_CLOSED then closed
            elsif status == ST_NEW then created
            else [time_on([start, TODAY - rand(0..3)].max), created].max
            end
  set_times(issue, created_on: created, updated_on: updated, closed_on: status.is_closed? ? closed : nil)
  [issue, due]
end

VERSIONS_TO_CLOSE = []

def create_plan(project, plan)
  members = project.assignable_users.to_a
  created = time_on(TODAY + plan[:start] - 7)
  day = next_working_day(TODAY + plan[:start])
  plan[:versions].each do |version_name, tasks|
    version = project.versions.find_by!(name: version_name)
    parent = Issue.new(project: project, tracker: TRACKERS[1], author: members.first, subject: version_name,
                       description: "#{version_name}のまとめ用チケット。子チケットで作業を管理する。",
                       priority: PRIORITIES[1], assigned_to: members.first, fixed_version: version)
    parent.save!
    children = []
    tasks.each do |name, days|
      if days.is_a?(Array) # a task with subtasks
        srand(Zlib.crc32(name))
        sub = Issue.new(project: project, tracker: TRACKERS[1], author: members.first, subject: name,
                        priority: PRIORITIES[1], assigned_to: members.sample, fixed_version: version, parent_issue_id: parent.id)
        sub.save!
        grandchildren = days.map do |sub_name, sub_days|
          issue, due = create_task(project, version, sub_name, day, sub_days, sub, members, created)
          day = next_working_day(due + 1)
          issue
        end
        grandchildren.each_cons(2) { |a, b| IssueRelation.create!(issue_from: a, issue_to: b, relation_type: 'precedes') }
        children << sub
      else
        issue, due = create_task(project, version, name, day, days, parent, members, created)
        day = next_working_day(due + 1)
        children << issue
      end
    end
    children.each_cons(2) { |a, b| IssueRelation.create!(issue_from: a, issue_to: b, relation_type: 'precedes') }

    # Parents: dates / progress / estimate are derived from the subtasks by Redmine; status follows them here
    [*children.select { |c| c.reload.children.any? }, parent].each do |p|
      p.reload
      kids = p.children.to_a
      status = if kids.all?(&:closed?) then ST_CLOSED
               elsif kids.any? { |k| k.status != ST_NEW } then ST_PROGRESS
               else ST_NEW
               end
      closed = kids.map(&:closed_on).compact.max
      set_times(p, status_id: status.id, created_on: created, updated_on: kids.map(&:updated_on).max,
                       closed_on: status == ST_CLOSED ? closed : nil)
    end
    # Redmine journals the subtask/relation additions on the parents at "now": move them to when the plan was made
    plan_ids = [parent.id, *children.map(&:id)]
    Journal.where(journalized_type: 'Issue', journalized_id: plan_ids).where('created_on >= ?', NOW)
           .update_all(created_on: created, updated_on: created)
    parent.reload
    version.update_columns(effective_date: parent.due_date, created_on: created, updated_on: created)
    VERSIONS_TO_CLOSE << version if parent.status == ST_CLOSED # closed at the end: closed versions can't be assigned
    day = next_working_day(day + 3) # a short gap between milestones
  end
end

started = Time.current

# Versions exist from the start so that ordinary issues can target them; their tasks are created at the end
PLANS.each do |identifier, plan|
  plan[:versions].each { |name, _| Version.create!(project: projects[identifier], name: name, status: 'open') }
end

# ---- issues & journals -------------------------------------------------------------------------------------------
ISSUES_PER_PROJECT.each do |identifier, count|
  project = projects[identifier]
  words = WORDS[identifier]
  members = project.users.to_a
  authors = members.presence || [admin]
  assignable = project.assignable_users.to_a
  versions = project.versions.to_a
  created_issues = []

  # Sorted so that issue ids follow creation dates, as in a real tracker
  Array.new(count) { NOW - rand(365 * 86_400) }.sort.each do |created|
    private_issue = identifier != 'general' && rand < 0.05
    age_days = (NOW - created) / 86_400
    status = pick_status(age_days)
    start_date = due_date = nil
    if rand < 0.5
      start_date = created.to_date if rand < 0.6
      due_date = created.to_date + rand(3..60)
    end

    title = subject(words)
    body = description(words)
    title = "【社外秘】#{title}" if private_issue
    body += "\n\n社外秘のため関係者以外に共有しないこと。" if private_issue

    issue = Issue.new(project: project, tracker: TRACKERS.sample, author: authors.sample, subject: title,
                      description: body, priority: weighted(PRIORITIES.zip([15, 60, 15, 7, 3]).to_h),
                      assigned_to: rand < 0.15 ? nil : assignable.sample, is_private: private_issue,
                      category: rand < 0.4 ? categories[identifier].sample : nil,
                      fixed_version: versions.any? && rand < 0.2 ? versions.sample : nil,
                      start_date: start_date, due_date: due_date,
                      estimated_hours: rand < 0.3 ? [0.5, 1, 2, 4, 8, 16, 24, 40].sample : nil,
                      done_ratio: done_ratio_for(status))
    issue.status = status
    issue.save!

    # History: the status changes and the notes, at random times between creation and the last update
    path = status_path(status)
    events = ([:status] * path.size + [:note] * note_count).shuffle
    files = rand < 0.15 ? pick_files(private_issue) : []
    events << :attach if files.any? && rand < 0.5 # attached later, with a note (otherwise attached when created)
    span = [NOW - created, (status.is_closed? ? 120 : 60).days.to_i].min
    times = Array.new(events.size) { created + rand * span }.sort
    previous = ST_NEW
    closed_at = nil
    events.zip(times).each do |kind, time|
      user = authors.sample
      case kind
      when :status
        to = path.shift
        notes = rand < 0.5 ? fill(STATUS_NOTES[to].sample, words) : ''
        add_journal(issue, user, time, notes: notes, details: [status_detail(previous, to)])
        closed_at = time if to.is_closed?
        previous = to
      when :note
        # Only roles allowed to (Manager, Developer) write private notes, as in real use
        add_journal(issue, user, time, notes: note(words),
                    private_notes: rand < 0.05 && user.allowed_to?(:set_notes_private, project))
      when :attach
        added = files.map { |f| attach(issue, f, user, time) }
        add_journal(issue, user, time, notes: '資料を添付します。',
                    details: added.map { |a| { property: 'attachment', prop_key: a.id.to_s, value: a.filename } })
        files = []
      end
    end
    files.each { |f| attach(issue, f, issue.author, created) }

    set_times(issue, created_on: created, updated_on: times.last || created, closed_on: closed_at)
    created_issues << issue
  end

  # A few links between issues
  (count / 50).times do
    a, b = created_issues.sample(2)
    IssueRelation.create(issue_from: a, issue_to: b, relation_type: %w[relates relates duplicates blocks].sample)
  end
  puts "#{identifier}: #{count} issues"
end

# ---- wiki pages ------------------------------------------------------------------------------------------------
WIKI_PAGES = {
  'search-platform' => %w[Wiki 全体構成 スキーマ設計 インデックス方式 運用手順 障害対応 用語集 開発環境],
  'dept-docs'       => %w[Wiki 文書管理規程 フォルダ構成 命名規則 保管期限一覧 棚卸し手順 よくある質問],
  'general'         => %w[Wiki 社内システム一覧 問い合わせ先 在宅勤務ガイド 新入社員向け 出張・交通のしおり]
}.freeze

WIKI_PAGES.each do |identifier, titles|
  project = projects[identifier]
  words = WORDS[identifier]
  authors = project.users.to_a.presence || [admin]
  titles.each do |title|
    text = +"# #{title}\n\n#{paragraph(words, 3)}\n"
    rand(2..6).times { text << "\n## #{fill('%{a}について', words)}\n\n#{paragraph(words, rand(3..8))}\n" }
    page = WikiPage.new(wiki: project.wiki, title: title)
    page.content = WikiContent.new(text: text, author: authors.sample)
    page.save!

    # Edited a few times: each save adds a version
    created = NOW - rand(300).days
    times = [created] + Array.new(rand(0..4)) { created + rand * (NOW - created) }.sort
    times.drop(1).each do
      page.content.text += "\n## #{fill('%{a}の追記', words)}\n\n#{paragraph(words, rand(1..4))}\n"
      page.content.author = authors.sample
      page.content.save!
    end
    page.content.versions.order(:version).zip(times).each { |v, t| v.update_columns(updated_on: t) }
    page.content.update_columns(updated_on: times.last)
    page.update_columns(created_on: created)
    pick_files(false).each { |f| attach(page, f, authors.sample, times.last) } if title.include?('交通') || rand < 0.25
  end
end

# ---- documents -------------------------------------------------------------------------------------------------
doc_categories = DocumentCategory.active.to_a
projects.each do |identifier, project|
  authors = project.users.to_a.presence || [admin]
  20.times do
    created = NOW - rand(365).days
    doc = Document.create!(project: project, category: doc_categories.sample,
                           title: fill(TITLES[:normal].sample, WORDS[identifier]),
                           description: description(WORDS[identifier]))
    doc.update_columns(created_on: created)
    pick_files(false).each { |f| attach(doc, f, authors.sample, created + rand(0..10).days) } if rand < 0.7
  end
end

# ---- planned tasks (last: how many journals they get depends on the date) ----------------------------------------
PLANS.each { |identifier, plan| create_plan(projects[identifier], plan) }
VERSIONS_TO_CLOSE.each { |v| v.update_columns(status: 'closed') }

status_counts = Issue.group(:status_id).count.transform_keys { |id| IssueStatus.find(id).name }
puts format('done in %.1fs: %d users, %d projects, %d issues (%d private), %d journals, %d relations, %d versions, ' \
            '%d wiki pages, %d documents, %d attachments',
            Time.current - started, User.where(type: 'User').count, Project.count, Issue.count,
            Issue.where(is_private: true).count, Journal.count, IssueRelation.count, Version.count,
            WikiPage.count, Document.count, Attachment.count)
puts "statuses: #{status_counts}"
