# The review shelf. Renders land here after the queue runs, Amy looks at them,
# and approved ones are pushed to their project repo.
#
#   .\review.ps1 status
#   .\review.ps1 add    -Job 1                      # ingest a finished queue job
#   .\review.ps1 add    -File D:\...\shot.mp4 -Project retina -Name mosaic
#                                                   # ingest a render made outside the queue
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
  [Parameter(Position = 0)][ValidateSet('status','add','approve','reject','publish','page','bury','unbury')]
  [string]$Command = 'status',
  [int]$Job, [int]$Id, [string]$Note = '',
  # Why a render was retired. Optional: some are buried simply for being an older
  # take, and inventing a fault for those would be worse than saying nothing.
  [string]$Issue = '',
  # An ad hoc render, one made outside the nightly queue. Not every render is
  # queued: a shot designed and run inside a single conversation never gets a job
  # id, and before this it could not be shelved at all, which meant the only
  # renders Amy could review were the ones that happened overnight.
  [string]$File, [string]$Project, [string]$Name
)

$ErrorActionPreference = 'Continue'
$RepoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile  = Join-Path $RepoDir 'review.json'
$MediaDir   = Join-Path $RepoDir 'media'
$QueueFile  = 'C:\Users\amyle\render-queue\render_queue.json'

$Destinations = @{
  ca3     = 'C:\Users\amyle\ca3'
  banc    = 'C:\Users\amyle\banc'
  microns = 'C:\Users\amyle\microns'
  retina  = 'C:\Users\amyle\retina'
}

# Where each project is published. Used to turn a verified hash match into a link
# the reader can click, so "deployed" is checkable rather than a claim.
$Projects_Url = @{
  ca3     = 'https://amyleesterling.github.io/ca3/'
  banc    = 'https://amyleesterling.github.io/banc/'
  microns = 'https://amyleesterling.github.io/microns/'
  retina  = 'https://amyleesterling.github.io/retina/'
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
    if ($File) {
      if (-not (Test-Path $File)) { Write-Error "no file at $File"; break }
      if (-not $Project -or -not $Name) { Write-Error "-File also needs -Project and -Name"; break }
      # Shaped like a queue job so everything downstream is unchanged. id 0 marks
      # it as having no job behind it.
      $j = [pscustomobject]@{
        id = 0; project = $Project; name = $Name; output = (Resolve-Path $File).Path
        finished = (Get-Date -Format 's'); note = $Note
      }
    } else {
      $q = ReadJson $QueueFile $null
      $j = @($q.jobs | Where-Object { $_.id -eq $Job })[0]
      if (-not $j) { Write-Error "no queue job #$Job"; break }
      if (-not $j.output -or -not (Test-Path $j.output)) { Write-Error "job #$Job has no output on disk"; break }
    }

    # Prefer the small web encode: reviewing on a phone should not pull a 24 MB
    # master. Two spellings exist in the wild because ChangeExtension leaves a
    # trailing dot, so check both rather than silently fall back to the big file.
    $src = $j.output
    $stem = [IO.Path]::Combine([IO.Path]::GetDirectoryName($j.output),
                               [IO.Path]::GetFileNameWithoutExtension($j.output))
    foreach ($cand in @("${stem}_web.mp4", "${stem}.web.mp4")) {
      if (Test-Path $cand) { $src = $cand; break }
    }
    if ($src -eq $j.output) { Write-Warning "no web encode found for $($j.name), using the master" }

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

  { $_ -in 'bury','unbury' } {
    foreach ($i in $state.items) {
      if ($i.id -eq $Id) {
        $i | Add-Member -NotePropertyName buried -NotePropertyValue ($Command -eq 'bury') -Force
        $i | Add-Member -NotePropertyName issue  -NotePropertyValue $Issue -Force
      }
    }
    WriteJson $StateFile $state
    & $PSCommandPath page
    Sync ("review: {0} #{1}" -f $Command, $Id)
    Write-Output ("#{0} -> {1}{2}" -f $Id, $Command, $(if ($Issue) { ": $Issue" } else { '' }))
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
    # ---- which section does each item belong in -------------------------------
    # Exactly one, so the top of the page holds only what still needs a decision.
    # Precedence: buried beats deployed beats OG beats needs-review.
    #
    # The OG cutoff is a FIXED DATE, not "before today". A relative cutoff would
    # quietly swallow the whole shelf as the days pass, and the section means
    # something specific: the work from the first 48 hours of this project.
    $OG_CUTOFF = [datetime]'2026-07-31T00:00:00'

    # DEPLOYED IS VERIFIED, NOT ASSERTED. A file is only called deployed if its
    # bytes are byte-for-byte identical to a file sitting in a project repo. A
    # name match would be a guess, and a render that was re-encoded or superseded
    # under the same name would be labelled live when it is not.
    $deployedHashes = @{}
    foreach ($proj in $Destinations.Keys) {
      $dir = $Destinations[$proj]
      if (-not (Test-Path $dir)) { continue }
      foreach ($f in Get-ChildItem $dir -Recurse -Include *.mp4 -ErrorAction SilentlyContinue) {
        $h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash
        if (-not $deployedHashes.ContainsKey($h)) {
          $deployedHashes[$h] = @{ project = $proj; url = $Projects_Url[$proj]; file = $f.Name }
        }
      }
    }

    foreach ($i in $state.items) {
      $sect = 'review'
      $dep = $null
      $local = Join-Path $RepoDir $i.video
      if (Test-Path $local) {
        $h = (Get-FileHash $local -Algorithm SHA256).Hash
        if ($deployedHashes.ContainsKey($h)) { $dep = $deployedHashes[$h] }
      }
      $rendered = if ($i.rendered) { [datetime]$i.rendered } else { [datetime]'1900-01-01' }
      if ($i.buried)         { $sect = 'graveyard' }
      elseif ($dep)          { $sect = 'deployed' }
      elseif ($rendered -lt $OG_CUTOFF) { $sect = 'og' }
      $i | Add-Member -NotePropertyName section -NotePropertyValue $sect -Force
      $i | Add-Member -NotePropertyName deployed_url -NotePropertyValue $(if ($dep) { $dep.url } else { '' }) -Force
      $i | Add-Member -NotePropertyName deployed_as -NotePropertyValue $(if ($dep) { $dep.file } else { '' }) -Force
    }

    # Newest render first. Sorting by id would give ingest order, which is not the
    # same thing: the shelf was backfilled with older renders in one pass, so their
    # ids run higher than work that was actually made earlier.
    $ordered = @($state.items | Sort-Object -Property `
        @{E = { if ($_.rendered) { [datetime]$_.rendered } else { [datetime]'1900-01-01' } } }, `
        @{E = { $_.id } } -Descending)

    function Render-Items($items) {
      $out = ''
      foreach ($i in $items) {
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
      $extra = ''
      if ($i.section -eq 'graveyard') {
        # An epitaph only when there is a real reason. Several of these were
        # buried simply for being an earlier take, and inventing a fault for
        # those would misrepresent the history.
        $extra = if ($i.issue) {
          '<p class="epitaph"><span class="rip">cause of death</span> ' + $i.issue + '</p>'
        } else {
          '<p class="epitaph"><span class="rip">cause of death</span> <em>natural causes, superseded</em></p>'
        }
      }
      if ($i.section -eq 'deployed' -and $i.deployed_url) {
        $extra = '<p class="live"><span class="dot"></span>live at <a href="' + $i.deployed_url +
                 '">' + $i.deployed_url + '</a> as <code>' + $i.deployed_as + '</code></p>'
      }
      $out += @"
  <article class="item $($i.status) sec-$($i.section)">
    <div class="hd"><span class="proj">$($i.project)</span><h2>$($i.name)</h2><span class="badge">$badge</span></div>
    <video controls playsinline muted loop preload="metadata" poster="$($i.poster)">
      <source src="$($i.video)" type="video/mp4">
    </video>
    <p class="meta">#$($i.id) &middot; $([string]::Join(' &middot; ', $meta))</p>
    <p class="note">$($i.note)</p>
    $rn
    $extra
  </article>

"@
      }
      return $out
    }

    $needs = Render-Items @($ordered | Where-Object { $_.section -eq 'review' })
    $live  = Render-Items @($ordered | Where-Object { $_.section -eq 'deployed' })
    $dead  = Render-Items @($ordered | Where-Object { $_.section -eq 'graveyard' })
    $og    = Render-Items @($ordered | Where-Object { $_.section -eq 'og' })
    if (-not $needs) { $needs = '  <p class="empty">Nothing waiting. Everything is deployed, buried or filed under OG.</p>' }

    $c_live = @($ordered | Where-Object { $_.section -eq 'deployed' }).Count
    $c_dead = @($ordered | Where-Object { $_.section -eq 'graveyard' }).Count
    $c_og   = @($ordered | Where-Object { $_.section -eq 'og' }).Count
    $n = @($ordered | Where-Object { $_.section -eq 'review' }).Count

    $rows = $needs
    if ($c_live) {
      $rows += @"

  <h2 class="sect"><span class="sicon">&#9679;</span>Deployed<span class="scount">$c_live</span></h2>
  <p class="sblurb">Byte-for-byte identical to a file currently sitting in a project repo. Verified by hash, not by filename.</p>
$live
"@
    }
    if ($c_dead) {
      $rows += @"

  <h2 class="sect grave"><span class="sicon">&#9760;</span>Graveyard<span class="scount">$c_dead</span></h2>
  <p class="sblurb">Here lie the renders that did not make it. They are kept because a wrong
  version you can still watch is worth more than one you deleted, and because most of these
  were only wrong in a way nobody could see until it was rendered.</p>
$dead
"@
    }
    if ($c_og) {
      $rows += @"

  <details class="ogwrap">
    <summary><span class="sicon">&#9733;</span>OG<span class="scount">$c_og</span><span class="sopen">the first 48 hours</span></summary>
    <p class="sblurb">Everything made before 31 July 2026, when this whole pipeline was two days old.</p>
$og
  </details>
"@
    }
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

  /* ---- section headers ---------------------------------------------------- */
  .sect { display:flex; align-items:center; gap:10px; margin:52px 0 4px;
          font-size:13px; font-weight:500; letter-spacing:.16em; text-transform:uppercase;
          color:var(--faint); padding-bottom:9px; border-bottom:1px solid var(--line); }
  .sicon { font-size:16px; line-height:1; }
  .scount { margin-left:auto; font-variant-numeric:tabular-nums; letter-spacing:.06em;
            color:var(--dim); }
  .sblurb { margin:12px 0 22px; font-size:14px; line-height:1.6; color:var(--dim); }

  /* ---- deployed ----------------------------------------------------------- */
  .sec-deployed { border-color:rgba(62,150,240,.34); }
  .live { margin:9px 0 0; font-size:13.5px; color:#7FC4F5; display:flex;
          align-items:center; gap:8px; flex-wrap:wrap; }
  .live a { color:#7FC4F5; }
  .live .dot { width:7px; height:7px; border-radius:50%; background:#3FBF8A;
               box-shadow:0 0 8px rgba(63,191,138,.9); flex:0 0 auto;
               animation:pulse 2.4s ease-in-out infinite; }
  @keyframes pulse { 0%,100% { opacity:1; } 50% { opacity:.35; } }

  /* ---- graveyard ----------------------------------------------------------
     Buried, not deleted. The stones lean, the video is drained of colour until
     you hover, and each one carries a cause of death where there is an honest
     one to give. */
  .sect.grave { color:#8FA0B4; border-bottom-color:#26303C; }
  .sect.grave .sicon { font-size:18px; filter:grayscale(1) opacity(.8); }
  .sec-graveyard {
    background:linear-gradient(180deg, rgba(18,22,29,.9), rgba(12,15,20,.9));
    border-color:#232B36; position:relative;
    border-radius:34px 34px 8px 8px;         /* a headstone */
    transform:rotate(-.5deg); transition:transform .3s ease, filter .3s ease;
  }
  .sec-graveyard:nth-of-type(even) { transform:rotate(.6deg); }
  .sec-graveyard:hover { transform:rotate(0deg); }
  .sec-graveyard video { filter:grayscale(.85) brightness(.72); transition:filter .45s ease; }
  .sec-graveyard:hover video { filter:grayscale(0) brightness(1); }
  .sec-graveyard h2 { color:#A9B6C6; }
  .epitaph { margin:10px 0 0; font-size:14px; color:#93A2B4; line-height:1.55; }
  .epitaph .rip { display:inline-block; font-size:10px; letter-spacing:.18em;
                  text-transform:uppercase; color:#6B7A8C; margin-right:8px; }
  .epitaph em { font-style:italic; color:#7D8B9C; }

  /* ---- OG, collapsed by default ------------------------------------------- */
  .ogwrap { margin:52px 0 0; }
  .ogwrap > summary {
    display:flex; align-items:center; gap:10px; cursor:pointer; list-style:none;
    font-size:13px; font-weight:500; letter-spacing:.16em; text-transform:uppercase;
    color:var(--faint); padding-bottom:9px; border-bottom:1px solid var(--line);
  }
  .ogwrap > summary::-webkit-details-marker { display:none; }
  .ogwrap > summary:hover { color:var(--dim); }
  .ogwrap > summary .sicon { color:#E8A93A; }
  .ogwrap > summary .sopen { font-size:10.5px; letter-spacing:.12em; color:#5A6472;
                             text-transform:none; }
  .ogwrap > summary .scount { margin-left:auto; }
  .ogwrap[open] > summary { margin-bottom:4px; }
  .ogwrap .item { opacity:.82; }
  footer { margin-top:40px; padding-top:18px; border-top:1px solid var(--line);
           font-size:14px; color:var(--faint); }
  code { font-family:ui-monospace,Consolas,monospace; font-size:13px; color:var(--dim); }
</style>
</head>
<body>
<div class="wrap">
  <h1>To review</h1>
  <p class="sub">$n waiting. Watch, then tell any agent to approve or reject by number.
  Everything already deployed, buried or from the first 48 hours is filed below.</p>

$rows
  <footer>
    <code>review.ps1 approve -Id N</code> &middot;
    <code>review.ps1 reject -Id N -Note "why"</code> &middot;
    <code>review.ps1 publish -Id N</code> &middot;
    <code>review.ps1 bury -Id N -Issue "why"</code><br>
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
