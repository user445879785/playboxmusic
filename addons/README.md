# Playbox Music add-ons

Copy a link below and paste it in **Settings › Add-ons › Add from Link**.
You can also paste the JSON itself, or a link to any web page that contains it.

| Add-on | What it finds | Link |
|---|---|---|
| Audius | Free music uploaded by artists | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/audius.json |
| Openverse Audio | Creative Commons and public domain audio | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/openverse.json |
| ccMixter | Remixes, a cappellas, instrumentals | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/ccmixter.json |
| Funkwhale (open.audio) | Openly licensed music on the fediverse | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/funkwhale.json |
| Wikimedia Commons | Public domain recordings | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/wikimedia-commons.json |
| Radio Browser | 50,000 live radio stations by name | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/radio-browser.json |
| Radio by Genre | Live radio stations by genre or mood | https://raw.githubusercontent.com/user445879785/playboxmusic/main/addons/radio-browser-genre.json |

## Writing your own

An add-on is a small JSON file: which address to search (`{query}` is replaced with your
words) and where each field is in the answer. Fields are dotted paths (`user.name`,
`files.0.url`); a value with `{braces}` is a template filled from each result.

```json
{
  "playbox": 1,
  "id": "my-source",
  "name": "My Source",
  "about": "What it is.",
  "homepage": "https://example.com",
  "search": {
    "url": "https://example.com/api/search?q={query}",
    "results": "data",
    "title": "title",
    "artist": "artist.name",
    "artwork": "cover",
    "audio": "https://example.com/stream/{id}",
    "duration": "duration",
    "durationUnit": "s",
    "stream": false
  }
}
```

A web page can carry an add-on inside `<script type="application/json">…</script>`, or link to
its file with `<link rel="playbox-addon" href="my-source.json">`.
