# musicbrainz_filter

EmergenceSystem filter that searches the MusicBrainz open music encyclopedia for artists. No API key required.

## Input

```json
{"query": "Daft Punk"}
```

| Field    | Type    | Default | Description              |
|----------|---------|---------|--------------------------|
| `query`  | string  | —       | Artist name or keyword   |
| `artist` | string  | —       | Alias for `query`        |
| `timeout`| integer | `10`    | HTTP timeout in seconds  |

## Output

Up to 10 embryos, one per artist:

```json
{
  "properties": {
    "url":    "https://musicbrainz.org/artist/056e4f3e-d505-4dad-8ec1-d04f521cbb56",
    "resume": "Group — French electronic music duo",
    "title":  "Daft Punk",
    "mbid":   "056e4f3e-d505-4dad-8ec1-d04f521cbb56",
    "source": "musicbrainz.org"
  }
}
```

## Capabilities

`musicbrainz`, `music`, `artists`, `albums`, `songs`, `metadata`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
