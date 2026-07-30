# The review shelf. Renders land here after the queue runs, Amy looks at them,
# and approved ones are pushed to their project repo.
#
#   .\review.ps1 status
#   .\review.ps1 add    -Job 1                      # ingest a finished queue job
#   .\review.ps1 approve -Id 1                      # mark it good
#   .\review.ps1 reject  -Id 1 -Note "too fast"     # mark it not good, with a reason
#   .\review.ps1 publish -Id 1                      # copy the approved file into its site repo
#   .\review.ps1 page                               # regenerate index.html
#
# WHY. A render finishing is not the same as a render being wanted. Before this,
# a finished mp4 sat in D:\Meshes\renders with nothing recording whether anyone
# had looked at it or what they thought. This shelf is that record.
#
# Approval is deliberately conversational: Amy watches the page, then tells any
# agent "approve the BANC one". The page is for LOOKING. The state is here.

[CmdletBinding()]
param(
  [Parameter(Position = 0)][ValidateSet('status','add','approve','reject','publish','page')]
  [string]$Command = 'status',
  [int]$Job, [int]$Id, [string]$Note = ''
)

$ErrorActionPreference = 'Continue'
$RepoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile  = Join-Path $RepoDir 'review.json'
$MediaDir   = Join-Path $RepoDir 'media'
$QueueFile  = "C:\Users\amyle\AppData\Local\Temp\q.json"

$Destinations = @{
  ca3     = 'C:\Users\amyle\ca3'
  banc    = 'C:\Users\amyle\banc'
  microns = 'C:\Users\amyle\microns'
}

function ReadJson($p, $fallback) {
  if (-not (Test-Path $p)) { return $fallback }
  ((Get-Content $p -Raw) -replace "^\xEF\xBB\xBF", '') | ConvertFrom-Json
}
function WriteJson($p, $o) {
  # no BOM: python, jq and any non-PowerShell reader choke on one
  [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
function Sync($msg) {
  Push-Location $RepoDir
  try {
    git add -A 2>&1 | Out-Null
    if (git status --porcelain) {
      git -c user.name='review' -c user.email='noreply@localhost' commit -q -m $msg 2>&1 | Out-Null
      git pull --rebase --quiet origin main 2>&1 | Out-Null
      git push --quiet origin main 2>&1 | Out-Null
    }
  } catch { Write-Warning 'review: could not sync to git, state is local only' }
  Pop-Location
}

$state = ReadJson $StateFile ([pscustomobject]@{ next_id = 1; items = @() })

switch ($Command) {

  'add' {
    $q = ReadJson $QueueFile $null
    $j = @($q.jobs | Where-Object { $_.id -eq $Job })[0]
    if (-not $j) { Write-Error "no queue job #$Job"; break }
    if (-not $j.output -or -not (Test-Path $j.output)) { Write-Error "job #$Job has no output on disk"; break }

    $src = $j.output
    $web = [IO.Path]::ChangeExtension($src, $null) + 'web.mp4'
    if (Test-Path $web) { $src = $web }        # prefer the small encode for review

    $base = '{0}_{1}' -f $j.project, $j.name
    $vid  = Join-Path $MediaDir "$base.mp4"
    $post = Join-Path $MediaDir "$base.jpg"
    Copy-Item $src $vid -Force
    # a poster is required or iOS shows a black rectangle until you press play
    ffmpeg -y -v error -ss 2 -i $vid -frames:v 1 -vf "scale=540:-2" $post 2>$null

    $dur = 0; $frames = 0
    try {
      $dur = [math]::Round([double](ffprobe -v error -show_entries format=duration -of csv=p=0 $vid), 1)
      $frames = [int](ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $vid)
    } catch {}

    $item = [pscustomobject]@{
      id = $state.next_id; job = $j.id; project = $j.project; name = $j.name
      video = "media/$base.mp4"; poster = "media/$base.jpg"
      size_mb = [math]::Round((Get-Item $vid).Length / 1MB, 1)
      seconds = $dur; frames = $frames
      rendered = $j.finished; status = 'pending'; note = $j.note; review_note = ''
      source = $j.output
    }
    $state.items = @($state.items) + $item
    $state.next_id = $state.next_id + 1
    WriteJson $StateFile $state
    & $PSCommandPath page
    Sync ("review: add #{0} {1}/{2}" -f $item.id, $j.project, $j.name)
    Write-Output ("added #{0}  {1}/{2}  {3}s  {4} MB" -f $item.id, $j.project, $j.name, $dur, $item.size_mb)
  }

  { $_ -in 'approve','reject' } {
    foreach ($i in $state.items) {
      if ($i.id -eq $Id) {
        $i.status = $(if ($Command -eq 'approve') { 'approved' } else { 'rejected' })
        if ($Note) { $i.review_note = $Note }
      }
    }
    WriteJson $StateFile $state
    & $PSCommandPath page
    Sync ("review: {0} #{1}" -f $Command, $Id)
    Write-Output ("#{0} -> {1}" -f $Id, $Command)
  }

  'publish' {
    $i = @($state.items | Where-Object { $_.id -eq $Id })[0]
    if (-not $i) { Write-Error "no review item #$Id"; break }
    if ($i.status -ne 'approved') { Write-Error ("#{0} is '{1}', not approved. Approve it first." -f $Id, $i.status); break }
    $dest = $Destinations[$i.project]
    if (-not $dest -or -not (Test-Path $dest)) { Write-Error ("no repo for project '{0}'" -f $i.project); break }

    New-Item -ItemType Directory -Force -Path (Join-Path $dest 'video'), (Join-Path $dest 'images') | Out-Null
    $vname = '{0}.mp4' -f $i.name
    $pname = '{0}_poster.jpg' -f $i.name
    Copy-Item (Join-Path $RepoDir $i.video)  (Join-Path $dest "video\$vname") -Force
    Copy-Item (Join-Path $RepoDir $i.poster) (Join-Path $dest "images\$pname") -Force
    foreach ($x in $state.items) { if ($x.id -eq $Id) { $x.status = 'published' } }
    WriteJson $StateFile $state
    & $PSCommandPath page
    Sync ("review: publish #{0}" -f $Id)

    Write-Output ''
    Write-Output ("Copied into {0}" -f $dest)
    Write-Output ("  video/{0}" -f $vname)
    Write-Output ("  images/{0}" -f $pname)
    Write-Output ''
    Write-Output 'Not committed, and the page copy is not written: where a render goes and'
    Write-Output 'what it is captioned are editorial. Add something like this, then commit:'
    Write-Output ''
    Write-Output ('  <video controls playsinline muted loop preload="metadata" poster="images/{0}">' -f $pname)
    Write-Output ('    <source src="video/{0}" type="video/mp4">' -f $vname)
    Write-Output '  </video>'
    Write-Output ''
  }

  'page' {
    $rows = ''
    foreach ($i in @($state.items | Sort-Object -Property @{E={$_.id}} -Descending)) {
      $badge = switch ($i.status) {
        'pending'   { 'pending' }
        'approved'  { 'approved' }
        'rejected'  { 'rejected' }
        'published' { 'published' }
      }
      $meta = @()
      if ($i.seconds) { $meta += ('{0}s' -f $i.seconds) }
      if ($i.frames)  { $meta += ('{0} frames' -f $i.frames) }
      if ($i.size_mb) { $meta += ('{0} MB' -f $i.size_mb) }
      if ($i.rendered){ $meta += $i.rendered }
      $rn = ''
      if ($i.review_note) { $rn = '<p class="rn">' + $i.review_note + '</p>' }
      $rows += @"
  <article class="item $($i.status)">
    <div class="hd"><span class="proj">$($i.project)</span><h2>$($i.name)</h2><span class="badge">$badge</span></div>
    <video controls playsinline muted loop preload="metadata" poster="$($i.poster)">
      <source src="$($i.video)" type="video/mp4">
    </video>
    <p class="meta">#$($i.id) &middot; $([string]::Join(' &middot; ', $meta))</p>
    <p class="note">$($i.note)</p>
    $rn
  </article>

"@
    }
    if (-not $rows) { $rows = '  <p class="empty">Nothing waiting. Renders appear here when the queue finishes one.</p>' }
    $n = @($state.items | Where-Object { $_.status -eq 'pending' }).Count
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>To review</title>
<meta name="robots" content="noindex">
<style>
  :root { --ink:#EFF2F7; --dim:#9AA2B1; --faint:#666E7C; --ground:#07080B;
          --panel:#0F1218; --line:#1D222B; --accent:#3E96F0; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--ground); color:var(--ink);
         font:400 17px/1.6 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif;
         -webkit-text-size-adjust:100%; }
  .wrap { max-width:760px; margin:0 auto; padding:28px 16px 80px; }
  h1 { margin:0 0 4px; font-size:26px; font-weight:500; letter-spacing:-.015em; }
  .sub { margin:0 0 26px; color:var(--dim); font-size:15px; }
  .item { margin:0 0 34px; padding:16px; background:var(--panel);
          border:1px solid var(--line); border-radius:10px; }
  .item.approved { border-color:rgba(23,160,107,.5); }
  .item.rejected { border-color:rgba(200,70,70,.45); opacity:.62; }
  .item.published { opacity:.5; }
  .hd { display:flex; align-items:baseline; gap:10px; flex-wrap:wrap; margin-bottom:12px; }
  .hd h2 { margin:0; font-size:19px; font-weight:500; }
  .proj { font-size:11px; letter-spacing:.11em; text-transform:uppercase; color:var(--accent); }
  .badge { margin-left:auto; font-size:11px; letter-spacing:.1em; text-transform:uppercase;
           color:var(--faint); }
  .approved .badge { color:#3FBF8A; }
  .rejected .badge { color:#D96A6A; }
  video { width:100%; height:auto; display:block; border-radius:6px; background:#000; }
  .meta { margin:11px 0 0; font-size:12.5px; letter-spacing:.05em; color:var(--faint); }
  .note { margin:6px 0 0; font-size:14.5px; color:var(--dim); }
  .rn { margin:8px 0 0; font-size:14.5px; color:#D9A0A0; }
  .empty { color:var(--dim); }
  footer { margin-top:40px; padding-top:18px; border-top:1px solid var(--line);
           font-size:14px; color:var(--faint); }
  code { font-family:ui-monospace,Consolas,monospace; font-size:13px; color:var(--dim); }
</style>
</head>
<body>
<div class="wrap">
  <h1>To review</h1>
  <p class="sub">$n waiting. Watch, then tell any agent to approve or reject by number.</p>

$rows
  <footer>
    <code>review.ps1 approve -Id N</code> &middot;
    <code>review.ps1 reject -Id N -Note "why"</code> &middot;
    <code>review.ps1 publish -Id N</code><br>
    Publishing copies the file into the project repo. It does not write the page
    copy or commit, because placement and caption are editorial.
  </footer>
</div>
</body>
</html>
"@
    [IO.File]::WriteAllText((Join-Path $RepoDir 'index.html'), $html, (New-Object Text.UTF8Encoding($false)))
    Write-Output ("page written, {0} item(s), {1} pending" -f @($state.items).Count, $n)
  }

  'status' {
    Write-Output ''
    Write-Output '  TO REVIEW'
    Write-Output '  ---------'
    if (-not @($state.items).Count) { Write-Output '  (nothing yet)'; Write-Output ''; break }
    '  {0,-3} {1,-8} {2,-22} {3,-10} {4,7}  {5}' -f 'id','project','name','status','sec','note'
    foreach ($i in @($state.items)) {
      '  {0,-3} {1,-8} {2,-22} {3,-10} {4,7}  {5}' -f $i.id,$i.project,$i.name,$i.status,$i.seconds,$i.note
    }
    Write-Output ''
  }
}

