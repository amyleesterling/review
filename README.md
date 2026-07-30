# review

**Renders waiting to be looked at.** The queue puts them here when it finishes
one. Amy watches, then approves or rejects. Approved renders are copied into
their project repo.

A finished render is not a wanted render. Before this shelf existed, an mp4 just
appeared in `D:\Meshes\renders` with nothing recording whether anyone had seen it.

```powershell
.\review.ps1 status
.\review.ps1 approve -Id 1
.\review.ps1 reject  -Id 1 -Note "too fast through the neck"
.\review.ps1 publish -Id 1
```

`publish` copies the video and poster into the project repo and prints the markup
to paste. It deliberately does **not** write the page copy or commit: where a
render goes and what it is captioned are editorial decisions.

Videos are the small web encodes, not the masters, because this gets watched on a
phone.
