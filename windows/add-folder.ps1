<#
.SYNOPSIS
  Makes an external source of redmine_solr_search from a folder: a Solr collection, ManifoldCF's connections and a job.

.DESCRIPTION
  For a ManifoldCF, a Solr and a Tika Server installed on Windows itself (docs/manual.md, 4.6). It makes what the manual's
  chapter 8 ("ManifoldCF's screens") makes by hand:
    1. the Solr collection (from the configset "src", which must have been uploaded: the manual's 4.1), unless it exists;
    2. the connections: allowed-documents, tika-server and content-limiter are shared by every source (kept when they
       exist); fs-<name>, fixed-<name> and solr-<name> belong to this source (<name> is the collection with - for _);
    3. the job: File system -> Allowed documents -> Tika Server -> Content limiter -> Metadata adjuster -> Solr.
  It never deletes nor overwrites: when a connection or the job of this source exists already, it stops; so it does
  when the collection exists, unless -UseExistingCollection (two jobs writing to one collection delete each other's
  documents).
  Registering the source on Redmine (the admin page, then each project's settings) stays a step of its own.

  The status of the Tika connection is never checked (with -TikaConnector rmeta it would be safe): in ManifoldCF 2.31 the check of the Tika Server connector
  keeps an HTTP connection, and the first document of the next job then waits 15 minutes (docs/solr-knowhow.md, ch. 11).

  The folder is read by ManifoldCF, under the account it runs as (SYSTEM, when it is a task of the Task Scheduler: the manual's 4.6): a mapped drive letter (Z:) does
  not exist for it, and files of OneDrive that are only in the cloud cannot be read by it.

.EXAMPLE
  .\add-folder.ps1 -Folder C:\solr-test2 -Collection src_win2 -Schedule manual -Start
#>
[CmdletBinding()]
param(
  # The folder to crawl, as ManifoldCF sees it
  [Parameter(Mandatory = $true)] [string] $Folder,
  # The Solr collection of the source (letters, digits, _ and -)
  [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9_-]+$')] [string] $Collection,
  # When ManifoldCF starts the job by itself: the minutes of every hour, comma separated (default 0: on the hour),
  # or "manual" for never
  [string] $Schedule = '0',
  # Start the job at once
  [switch] $Start,
  # Print what would be sent, and send nothing
  [switch] $DryRun,
  # Use the Solr collection when it exists already (by default, the script stops: another job may be writing to it)
  [switch] $UseExistingCollection,
  [string] $McfUrl = 'http://127.0.0.1:8345',
  [string] $SolrUrl = 'http://127.0.0.1:8983/solr',
  [string] $TikaHost = '127.0.0.1',
  [int] $TikaPort = 9998,
  # Which Tika Server connector: server ("Tika external content extractor", the one the manual's chapter 8 uses) or rmeta ("Tika
  # external rmeta content extractor", which closes its HTTP responses). rmeta does NOT work with Tika Server 4.x: it looks
  # for the text under X-TIKA:content, which Tika 4 names tk:content, and sends documents with no text (ManifoldCF 2.31)
  [ValidateSet('server', 'rmeta')] [string] $TikaConnector = 'server',
  [string] $ConfigSet = 'src'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$name = $Collection -replace '_', '-'
if ($TikaConnector -eq 'rmeta') {
  Write-Warning 'rmeta works with Tika Server up to 3.x only: with Tika 4.x the documents go to Solr without their text.'
  $tikaName = 'tika-rmeta'; $tikaClass = 'org.apache.manifoldcf.agents.transformation.tikaservice.rmeta.TikaExtractor'
} else {
  $tikaName = 'tika-server'; $tikaClass = 'org.apache.manifoldcf.agents.transformation.tikaservice.TikaExtractor'
}
$api = "$McfUrl/mcf-api-service/json"
$solr = [Uri] $SolrUrl

# The same lists as the plugin's attachments and docs/experiments/m4-manifoldcf/setup.py
$extensions = 'doc docx xls xlsx ppt pptx odt ods odp rtf txt md csv tsv json xml html htm log yml yaml ini conf pdf' -split ' '
$mimeTypes = @(
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.oasis.opendocument.text', 'application/vnd.oasis.opendocument.spreadsheet',
  'application/vnd.oasis.opendocument.presentation', 'application/rtf', 'text/rtf', 'application/pdf', 'text/plain',
  'text/markdown', 'text/csv', 'text/tab-separated-values', 'application/json', 'application/xml', 'text/xml',
  'text/html', 'application/xhtml+xml', 'application/x-yaml', 'text/yaml', 'text/x-yaml', 'text/x-web-markdown',
  'text/x-log', 'text/x-ini', 'application/octet-stream')
$excluded = @('._*', '.DS_Store', 'Thumbs.db', 'desktop.ini',
  '*.zip', '*.tar', '*.gz', '*.tgz', '*.bz2', '*.xz', '*.7z', '*.rar', '*.jar', '*.war', '*.cab', '*.iso')

# A node of ManifoldCF's JSON: {"_type_": kind, "_attribute_<name>": value, ...}
function McfNode([string] $kind, [hashtable] $attributes = @{}, $children = $null, $value = $null) {
  $n = [ordered] @{ '_type_' = $kind }
  foreach ($k in $attributes.Keys) { $n["_attribute_$k"] = [string] $attributes[$k] }
  if ($null -ne $value) { $n['_value_'] = [string] $value }
  if ($null -ne $children) { $n['_children_'] = @($children) }
  $n
}
function McfParam([string] $parameterName, $value) { McfNode '_PARAMETER_' @{ name = $parameterName } -value $value }

function Call([string] $method, [string] $path, $body = $null) {
  $uri = "$api$path"
  if ($DryRun -and $method -ne 'GET') {
    Write-Host "--- $method $uri"
    if ($null -ne $body) { Write-Host ($body | ConvertTo-Json -Depth 30) }
    return @{}
  }
  $request = @{ Method = $method; Uri = $uri; UseBasicParsing = $true }
  if ($null -ne $body) {
    # Windows PowerShell 5.1 would send a string as ISO-8859-1: send UTF-8 bytes (a folder name in Japanese)
    $request.Body = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 30))
    $request.ContentType = 'application/json; charset=utf-8'
  }
  $response = Invoke-WebRequest @request
  $text = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
  if ($text.Trim()) { $text | ConvertFrom-Json } else { $null }
}

function Exists([string] $plural, [string] $kind, [string] $connection) {
  # a connection that is not there: an empty answer, or an error status
  try { $answer = Call 'GET' "/$plural/$connection" } catch { return $false }
  return ($null -ne $answer) -and ($answer.PSObject.Properties.Name -contains $kind)
}

function Put-Connection([string] $plural, [string] $kind, [string] $connection, [string] $class, [string] $description,
                        $config = @(), [int] $maxConnections = 10) {
  $body = @{ $kind = [ordered] @{
      name = $connection; class_name = $class; description = $description; max_connections = [string] $maxConnections
      configuration = @{ '_children_' = @($config) } } }
  $answer = Call 'PUT' "/$plural/$connection" $body
  if ($answer -and $answer.error) { throw "PUT /$plural/${connection}: $($answer.error)" }
  Write-Host "made $plural/$connection"
}

function Check-Connection([string] $plural, [string] $connection) {
  if ($DryRun) { return }
  $answer = Call 'GET' "/status/$plural/$connection"
  Write-Host "  status of ${connection}: $($answer.check_result)"
  if ($answer.check_result -ne 'Connection working') {
    throw "$connection is not working: $($answer.check_result)"
  }
}

# --- before anything: the folder, ManifoldCF, Solr and the configset

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "no such folder: $Folder" }
$drive = (Split-Path -Qualifier $Folder -ErrorAction SilentlyContinue) -replace ':$', ''
if ($drive -and (Get-PSDrive -Name $drive -PSProvider FileSystem -ErrorAction SilentlyContinue).DisplayRoot) {
  Write-Warning "$($drive): is a mapped network drive: ManifoldCF, as a service, does not see it. Give its UNC path."
}
if ($Folder -match '\\OneDrive') {
  Write-Warning 'A OneDrive folder: files that are only in the cloud cannot be read by ManifoldCF as a service.'
}

try { Invoke-WebRequest -UseBasicParsing "$McfUrl/mcf-crawler-ui/" | Out-Null } catch { throw "ManifoldCF does not answer at $McfUrl" }
$configSets = (Invoke-RestMethod "$SolrUrl/admin/configs?action=LIST").configSets
if ($configSets -notcontains $ConfigSet) {
  throw "Solr has no configset '$ConfigSet': upload it first (docs/manual.md, 4.1)"
}

foreach ($own in @(@('repositoryconnections', 'repositoryconnection', "fs-$name"),
                   @('transformationconnections', 'transformationconnection', "fixed-$name"),
                   @('outputconnections', 'outputconnection', "solr-$name"))) {
  if (Exists $own[0] $own[1] $own[2]) { throw "ManifoldCF has a connection $($own[2]) already: nothing done" }
}
$jobs = (Call 'GET' '/jobs').job
$same = @($jobs | Where-Object { $_ } | ForEach-Object {
    $j = @{}; foreach ($c in $_.'_children_') { $j[$c.'_type_'] = $c.'_value_' }; $j } |
    Where-Object { $d = [string] $_.description; $d -eq $Collection -or $d.StartsWith("$Collection ") })
if ($same.Count -gt 0) { throw "ManifoldCF has a job of $Collection already (id $($same[0].id)): nothing done" }

# --- 1. the collection

$collections = (Invoke-RestMethod "$SolrUrl/admin/collections?action=LIST").collections
if ($collections -contains $Collection) {
  if (-not $UseExistingCollection) {
    throw "Solr has a collection $Collection already: give another name, or -UseExistingCollection to use it"
  }
  Write-Host "Solr collection $Collection exists: used as it is"
} elseif ($DryRun) {
  Write-Host "--- would make the Solr collection $Collection (configset $ConfigSet)"
} else {
  $r = Invoke-RestMethod "$SolrUrl/admin/collections?action=CREATE&name=$Collection&numShards=1&replicationFactor=1&collection.configName=$ConfigSet"
  if ($r.responseHeader.status -ne 0) { throw "Solr did not make $Collection" }
  Write-Host "made the Solr collection $Collection"
}

# --- 2. the connections

if (-not (Exists 'transformationconnections' 'transformationconnection' 'allowed-documents')) {
  Put-Connection 'transformationconnections' 'transformationconnection' 'allowed-documents' `
    'org.apache.manifoldcf.agents.transformation.documentfilter.DocumentFilter' 'Allowed documents'
}
if (-not (Exists 'transformationconnections' 'transformationconnection' $tikaName)) {
  # few calls at a time: Tika Server refuses many at once (docs/experiments/m4-manifoldcf, round 6)
  $tikaConfig = @((McfParam 'tikaHostname' $TikaHost), (McfParam 'tikaPort' $TikaPort))
  if ($TikaConnector -eq 'rmeta') {
    # the rmeta connector reads these and fails on a missing one ("Bad connection timeout number: null"); its screen fills
    # them in, the API does not: the defaults of its TikaConfig (release-2.31), in milliseconds
    $tikaConfig += @((McfParam 'connectionTimeout' '60000'), (McfParam 'socketTimeout' '60000'),
                     (McfParam 'retryInterval' '20000'), (McfParam 'retryIntervalTikaDown' '120000'), (McfParam 'retryNumber' '1'))
  }
  Put-Connection 'transformationconnections' 'transformationconnection' $tikaName $tikaClass "Tika Server ($TikaConnector)" `
    $tikaConfig 4
}
if (-not (Exists 'transformationconnections' 'transformationconnection' 'content-limiter')) {
  Put-Connection 'transformationconnections' 'transformationconnection' 'content-limiter' `
    'org.apache.manifoldcf.agents.transformation.contentlimiter.ContentLimiter' 'Content limiter'
}
Put-Connection 'repositoryconnections' 'repositoryconnection' "fs-$name" `
  'org.apache.manifoldcf.crawler.connectors.filesystem.FileConnector' "File system ($Folder)"
Check-Connection 'repositoryconnections' "fs-$name"
Put-Connection 'transformationconnections' 'transformationconnection' "fixed-$name" `
  'org.apache.manifoldcf.agents.transformation.forcedmetadata.ForcedMetadataConnector' 'Metadata adjuster'
# straight to the Solr node (not through ZooKeeper): docs/experiments/windows-mcf
Put-Connection 'outputconnections' 'outputconnection' "solr-$name" `
  'org.apache.manifoldcf.agents.output.solr.SolrConnector' $Collection @(
    (McfParam 'Solr type' 'standard'), (McfParam 'Server protocol' $solr.Scheme), (McfParam 'Server name' $solr.Host),
    (McfParam 'Server port' $solr.Port), (McfParam 'Server web application' $solr.AbsolutePath.Trim('/')),
    (McfParam 'Solr core name' $Collection),
    (McfParam 'Server update handler' '/update'), (McfParam 'Server remove handler' '/update'),
    (McfParam 'Server status handler' '/admin/ping'),
    (McfParam 'Use extract update handler' 'false'),
    (McfParam 'Solr id field name' 'id'), (McfParam 'Solr content field name' 'content'),
    (McfParam 'Solr filename field name' 'title'), (McfParam 'Solr modified date field name' 'updated_at'),
    (McfParam 'Maximum document length' '52428800'),
    (McfParam 'Commits' 'true'), (McfParam 'Commit within' '10000'))
Check-Connection 'outputconnections' "solr-$name"

# --- 3. the job

$rules = @($excluded | ForEach-Object { McfNode 'exclude' @{ type = 'file'; match = $_ } }) +
         @((McfNode 'include' @{ type = 'file'; match = '*' }), (McfNode 'include' @{ type = 'directory'; match = '*' }))
# each stage: its connection and its specification (hashtables: an array of arrays would be flattened)
$stages = @(
  # the lists are the text of their nodes, one to a line (a "value" attribute would let nothing through)
  @{ connection = 'allowed-documents'
     spec = @((McfNode 'extensions' -value ($extensions -join "`n")), (McfNode 'mimetypes' -value ($mimeTypes -join "`n")),
              (McfNode 'maxlength' @{ value = '52428800' })) },
  @{ connection = $tikaName
     spec = @((McfNode 'keepAllMetadata' @{ value = 'false' }), (McfNode 'lowerNames' @{ value = 'false' }),
              (McfNode 'ignoreException' @{ value = 'false' }), (McfNode 'writeLimit' @{ value = '10000000' })) },
  @{ connection = 'content-limiter'
     spec = @((McfNode 'maxlength' @{ value = '3000000' })) },
  @{ connection = "fixed-$name"
     spec = @((McfNode 'keepAllMetadata' @{ value = 'false' }), (McfNode 'filterEmpty' @{ value = 'true' }),
              (McfNode 'expression' @{ parameter = 'url'; value = 'file:${uri}' }),
              (McfNode 'expression' @{ parameter = 'path'; value = '${uri}' })) }
)
$pipeline = @()
for ($i = 0; $i -lt $stages.Count; $i++) {
  $stage = [ordered] @{ stage_id = [string] $i; stage_isoutput = 'false'; stage_connectionname = $stages[$i].connection
                        stage_specification = @{ '_children_' = @($stages[$i].spec) } }
  if ($i -gt 0) { $stage.stage_prerequisite = [string] ($i - 1) }
  $pipeline += $stage
}
$pipeline += [ordered] @{ stage_id = [string] $stages.Count; stage_prerequisite = [string] ($stages.Count - 1)
                          stage_isoutput = 'true'; stage_connectionname = "solr-$name"
                          stage_specification = @{ '_children_' = @() } }

$job = [ordered] @{
  description = "$Collection ($Folder)"; repository_connection = "fs-$name"
  document_specification = @{ '_children_' = @((McfNode 'startpoint' @{ path = $Folder } $rules)) }
  run_mode = 'scan once'; hopcount_mode = 'accurate'; priority = '5'; pipelinestage = $pipeline }
if ($Schedule -eq 'manual') {
  $job.start_mode = 'manual'
} else {
  # a window starts at each of those minutes; with no duration, a run is never cut short
  $job.start_mode = 'schedule window start'
  $job.schedule = @(@{ minutesofhour = @{ value = @($Schedule -split ',' | ForEach-Object { [int] $_.Trim() }) } })
}
$answer = Call 'POST' '/jobs' @{ job = $job }
if ($answer -and $answer.error) { throw "POST /jobs: $($answer.error)" }
$jobId = $answer.job_id
Write-Host "made the job $jobId ($Collection, schedule: $Schedule)"

if ($Start -and -not $DryRun) {
  Call 'PUT' "/start/$jobId" | Out-Null
  Write-Host "started the job ${jobId}: see ManifoldCF's 'Status and job management'"
}
Write-Host "Next: register $Collection on Redmine (Administration > Full-text search > External sources) and link it to projects."
