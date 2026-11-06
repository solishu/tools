# bargaining-transcript

Turns a long recorded session into a timestamped, readable transcript you can hand to an
LLM for summarisation. Written for long multi-speaker recordings (bargaining sessions,
board meetings, public hearings) where you want to know what was discussed without
sitting through the whole thing.

Runs on macOS (Apple Silicon or Intel).

## How it works

Cheapest path first:

1. For a YouTube URL, fetch the platform's own captions (human-made or automatic). This
   takes seconds and skips transcription.
2. If there are none, or the source is a local file, extract the audio and run Whisper
   locally. Nothing is uploaded.
3. Either way, clean the captions into deduplicated paragraphs anchored by timestamps.
   YouTube's rolling auto-captions repeat each phrase across cues; the cleaner overlaps
   them so each phrase appears once.

## Usage

```bash
./bargaining-transcript.sh <youtube-url | local-audio-file> [options]
```

| Option | Meaning |
|---|---|
| `-o`, `--outdir DIR` | Output directory (default `./transcript-<slug>`) |
| `-m`, `--model NAME` | Whisper model: `tiny`, `base`, `small` (default), `medium`, `large` |
| `--skip-captions` | Skip platform captions; go straight to Whisper |
| `--captions-only` | Try captions; fail rather than fall back to Whisper |
| `--interval SECS` | Seconds between timestamp anchors (default 60) |
| `--keep-audio` | Keep the extracted audio when finished |
| `--install-deps` | Install missing dependencies via Homebrew and pipx, then exit |
| `-h`, `--help` | Show the usage text |

Whisper runs on the CPU: budget roughly the length of the recording, sometimes more.

## Output

In the output directory:

- `transcript.txt`: the cleaned, deduplicated, timestamped transcript. Attach this one.
- `captions.vtt` or `whisper.vtt`: the raw machine output, kept for reference.
- `SOURCE.txt`: what was fetched, when, and by which path.

The transcript carries no speaker attribution. Check anything you quote from it against
the audio.

## Requirements

`python3`, `ffmpeg`, `yt-dlp` (URLs only) and `whisper` (`openai-whisper`, unless
`--captions-only`). `--install-deps` installs them through Homebrew and pipx.

## History

Written 2026-09-03 and committed to a branch of `solishu/Skills` that never merged;
moved here unchanged on 2026-11-06.
