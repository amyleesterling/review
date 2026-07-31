# Put every finished render on the review shelf, not just the ones the queue ran.
#
# The shelf's `add` reads a job out of render_queue.json, but several renders were
# started directly against a deadline and never went through the queue. This walks
# the renders folder instead, so nothing that exists is invisible.

$ErrorActionPreference = 'Continue'
$R = 'D:\Meshes\renders'
$RepoDir = 'C:\Users\amyle\review'
$MediaDir = Join-Path $RepoDir 'media'
$StateFile = Join-Path $RepoDir 'review.json'
New-Item -ItemType Directory -Force -Path $MediaDir | Out-Null

# name -> project, note. Only finished pieces, not probes or beat stills.
$items = @(
  @{ f='retina_final.mp4';        p='retina';  n='ds_mosaic_final'; note='202 calcium-imaged cells, CA3 palette, somas to camera, with readout overlays' }
  @{ f='retina_ds.mp4';           p='retina';  n='ds_mosaic_v1';    note='first pass: rainbow palette, somas facing away. superseded' }
  @{ f='microns_orbit.mp4';       p='microns'; n='cortex_orbit';    note='orbit 72 deg then descend, per-area decimated' }
  @{ f='gradient_orbit.mp4';      p='ca3';     n='gradient_orbit';  note='sixth of a turn across the convergence gradient' }
  @{ f='build_sequence_wide.mp4'; p='ca3';     n='build_sequence';  note='widescreen master, populations in circuit order' }
  @{ f='synapse_story_wide.mp4';  p='ca3';     n='synapse_story';   note='widescreen master, the synapse sequence' }
  @{ f='scale_ladder.mp4';        p='ca3';     n='scale_ladder';    note='block to cell to thorn to synapse' }
  @{ f='inhibition.mp4';          p='ca3';     n='inhibition';      note='feedforward inhibition, 7 beats' }
  @{ f='ap_six.mp4';              p='ca3';     n='ap_six_fibre';    note='six mossy fibres, one fails and six together succeed' }
  @{ f='cell_partners.mp4';       p='ca3';     n='cell_partners';   note='56 partner segments in purple' }
  @{ f='banc_shotB.mp4';          p='banc';    n='shotB_descending';note='one descending neuron, six body parts' }
)

function ReadJson($p, $fb) {
  if (-not (Test-Path $p)) { return $fb }
  ((Get-Content $p -Raw) -replace "^\xEF\xBB\xBF", '') | ConvertFrom-Json
}
$state = ReadJson $StateFile ([pscustomobject]@{ next_id = 1; items = @() })
$existing = @{}
foreach ($i in @($state.items)) { $existing["$($i.project)/$($i.name)"] = $true }

$added = 0
foreach ($it in $items) {
  $src = Join-Path $R $it.f
  if (-not (Test-Path $src)) { Write-Output ("  skip (not rendered): {0}" -f $it.f); continue }
  $key = "$($it.p)/$($it.n)"
  if ($existing.ContainsKey($key)) { Write-Output ("  already on shelf: {0}" -f $key); continue }

  # prefer a small web encode; two spellings exist in the wild
  $stem = [IO.Path]::Combine($R, [IO.Path]::GetFileNameWithoutExtension($it.f))
  $use = $src
  foreach ($c in @("${stem}_web.mp4", "${stem}.web.mp4")) { if (Test-Path $c) { $use = $c; break } }

  $base = "$($it.p)_$($it.n)"
  $vid = Join-Path $MediaDir "$base.mp4"
  $post = Join-Path $MediaDir "$base.jpg"
  Copy-Item $use $vid -Force
  ffmpeg -y -v error -ss 2 -i $vid -frames:v 1 -vf "scale=540:-2" $post 2>$null

  $dur = 0.0; $frames = 0
  try {
    $dur = [math]::Round([double](ffprobe -v error -show_entries format=duration -of csv=p=0 $vid), 1)
    $frames = [int](ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 $vid)
  } catch {}

  $state.items = @($state.items) + [pscustomobject]@{
    id = $state.next_id; job = 0; project = $it.p; name = $it.n
    video = "media/$base.mp4"; poster = "media/$base.jpg"
    size_mb = [math]::Round((Get-Item $vid).Length / 1MB, 1)
    seconds = $dur; frames = $frames
    rendered = (Get-Item $src).LastWriteTime.ToString('s')
    status = 'pending'; note = $it.note; review_note = ''; source = $src
  }
  $state.next_id = $state.next_id + 1
  $added++
  Write-Output ("  added {0}  {1}s  {2} MB" -f $key, $dur, [math]::Round((Get-Item $vid).Length / 1MB, 1))
}

[IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json -Depth 8),
                        (New-Object Text.UTF8Encoding($false)))
Write-Output ("  {0} added, {1} on the shelf total" -f $added, @($state.items).Count)
& (Join-Path $RepoDir 'review.ps1') page
