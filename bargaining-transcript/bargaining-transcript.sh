#!/usr/bin/env bash
#
# bargaining-transcript.sh — turn a long recorded session into a timestamped,
# readable transcript you can hand to an LLM for summarisation.
#
# Runs on macOS (Apple Silicon or Intel). Intended for long multi-speaker
# recordings — bargaining sessions, board meetings, public hearings — where
# you want to know what was discussed without sitting through the whole thing.
#
# Strategy, cheapest path first:
#   1. If the source is a YouTube URL, try to fetch the platform's own
#      auto-captions. Costs seconds. Skips transcription entirely.
#   2. If there are no captions, download the audio and run Whisper locally.
#      Nothing leaves your machine.
#   3. Either way, normalise the resulting VTT into deduplicated,
#      timestamp-anchored paragraphs.
#
# Usage:
#   ./bargaining-transcript.sh <youtube-url | local-audio-file> [options]
#
#   -o, --outdir DIR     Output directory (default: ./transcript-<slug>)
#   -m, --model NAME     Whisper model: tiny|base|small|medium|large
#                        (default: small — enough for gist, much faster)
#       --skip-captions  Don't try platform captions; go straight to Whisper
#       --captions-only  Try captions; fail rather than falling back to Whisper
#       --interval SECS  Seconds between timestamp anchors (default: 60)
#       --keep-audio     Don't delete the extracted audio when finished
#       --install-deps   Install missing dependencies via Homebrew/pipx, then exit
#   -h, --help           Show this message
#
# Output (in the chosen directory):
#   captions.vtt / whisper.vtt   raw machine output, kept for reference
#   transcript.txt               cleaned, deduplicated, timestamped — attach this
#   SOURCE.txt                   what was fetched, when, and by which path
#
set -euo pipefail

# ---------------------------------------------------------------- defaults ---

MODEL="small"
INTERVAL=60
OUTDIR=""
SKIP_CAPTIONS=0
CAPTIONS_ONLY=0
KEEP_AUDIO=0
SOURCE=""

die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ------------------------------------------------------------------- args ---

[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)       usage ;;
    -o|--outdir)     OUTDIR="${2:-}";   shift 2 ;;
    -m|--model)      MODEL="${2:-}";    shift 2 ;;
    --interval)      INTERVAL="${2:-}"; shift 2 ;;
    --skip-captions) SKIP_CAPTIONS=1;   shift ;;
    --captions-only) CAPTIONS_ONLY=1;   shift ;;
    --keep-audio)    KEEP_AUDIO=1;      shift ;;
    --install-deps)  INSTALL_DEPS=1;    shift ;;
    -*)              die "unknown option: $1" ;;
    *)               SOURCE="$1";       shift ;;
  esac
done

INSTALL_DEPS="${INSTALL_DEPS:-0}"

[[ "$MODEL" =~ ^(tiny|base|small|medium|large|large-v2|large-v3)$ ]] \
  || die "unrecognised model '$MODEL' (tiny|base|small|medium|large)"
[[ "$INTERVAL" =~ ^[0-9]+$ ]] || die "--interval needs a whole number of seconds"

# ------------------------------------------------------------ dependencies ---

have() { command -v "$1" >/dev/null 2>&1; }

install_deps() {
  have brew || die "Homebrew not found. Install it from https://brew.sh first."
  step "Installing dependencies"
  brew install yt-dlp ffmpeg
  if ! have pipx; then brew install pipx && pipx ensurepath; fi
  pipx install openai-whisper || pipx upgrade openai-whisper
  printf '\nDone. Open a new terminal tab so PATH changes take effect, then re-run.\n'
  exit 0
}

[[ "$INSTALL_DEPS" == "1" ]] && install_deps

check_deps() {
  local missing=()
  have python3 || missing+=("python3 (install Xcode Command Line Tools: xcode-select --install)")
  have ffmpeg  || missing+=("ffmpeg (brew install ffmpeg)")
  # yt-dlp only matters for URLs; whisper only if we may need to transcribe.
  if [[ "$IS_URL" == "1" ]]; then
    have yt-dlp || missing+=("yt-dlp (brew install yt-dlp)")
  fi
  if [[ "$CAPTIONS_ONLY" == "0" ]]; then
    have whisper || missing+=("whisper (pipx install openai-whisper)")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    printf '\nMissing dependencies:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    printf '\nRun with --install-deps to install them automatically.\n' >&2
    exit 1
  fi
}

# ----------------------------------------------------------------- source ---

[[ -n "$SOURCE" ]] || die "no source given (a YouTube URL or a local audio file)"

if [[ "$SOURCE" =~ ^https?:// ]]; then
  IS_URL=1
else
  IS_URL=0
  [[ -f "$SOURCE" ]] || die "no such file: $SOURCE"
  SKIP_CAPTIONS=1   # a local file has no platform captions to fetch
  [[ "$CAPTIONS_ONLY" == "1" ]] && die "--captions-only makes no sense for a local file"
fi

check_deps

# Build a filesystem-safe slug for naming.
if [[ "$IS_URL" == "1" ]]; then
  SLUG="$(yt-dlp --print id --no-warnings --skip-download "$SOURCE" 2>/dev/null | head -1 || true)"
  [[ -n "$SLUG" ]] || die "could not read that URL. Check it's public and yt-dlp is current (brew upgrade yt-dlp)."
else
  SLUG="$(basename "${SOURCE%.*}" | tr -cs '[:alnum:]._-' '-')"
fi

OUTDIR="${OUTDIR:-./transcript-$SLUG}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

VTT=""          # set once we have machine output to clean
METHOD=""

# ---------------------------------------------------- step 1: try captions ---

if [[ "$SKIP_CAPTIONS" == "0" ]]; then
  step "Looking for platform captions"
  # --write-subs picks up human-made subtitles; --write-auto-subs the machine ones.
  # en.* catches en, en-US, en-orig and similar variants.
  yt-dlp \
    --skip-download \
    --write-subs --write-auto-subs \
    --sub-langs "en.*,en" \
    --convert-subs vtt \
    --no-warnings \
    -o "$OUTDIR/%(id)s.%(ext)s" \
    "$SOURCE" >/dev/null 2>&1 || true

  # yt-dlp names these <id>.<lang>.vtt; take the first match.
  found="$(find "$OUTDIR" -maxdepth 1 -name "${SLUG}*.vtt" -print -quit 2>/dev/null || true)"
  if [[ -n "$found" ]]; then
    mv "$found" "$OUTDIR/captions.vtt"
    find "$OUTDIR" -maxdepth 1 -name "${SLUG}*.vtt" -delete 2>/dev/null || true
    VTT="$OUTDIR/captions.vtt"
    METHOD="platform auto-captions"
    note "Found captions — no transcription needed."
  else
    note "No captions available for this video."
    [[ "$CAPTIONS_ONLY" == "1" ]] && die "--captions-only was set and none were found."
    note "Falling back to local transcription."
  fi
fi

# --------------------------------------------- step 2: audio + transcribe ---

AUDIO=""
if [[ -z "$VTT" ]]; then

  if [[ "$IS_URL" == "1" ]]; then
    step "Downloading audio"
    note "Large sessions take a few minutes."
    yt-dlp -f bestaudio -x --audio-format mp3 \
      --no-warnings \
      -o "$OUTDIR/${SLUG}.%(ext)s" \
      "$SOURCE"
    AUDIO="$OUTDIR/${SLUG}.mp3"
    [[ -f "$AUDIO" ]] || die "audio download failed"
  else
    AUDIO="$SOURCE"
  fi

  DURATION="$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$AUDIO" 2>/dev/null || echo 0)"
  MINS="$(printf '%.0f' "$(echo "${DURATION:-0} / 60" | bc -l 2>/dev/null || echo 0)")"

  step "Transcribing with Whisper (model: $MODEL)"
  note "Audio length: ~${MINS} min."
  note "This runs on CPU and is slow — budget roughly the length of the"
  note "recording itself, sometimes more. Leave it running."
  note "Nothing is uploaded; this is entirely local."

  whisper "$AUDIO" \
    --model "$MODEL" \
    --language en \
    --output_format vtt \
    --output_dir "$OUTDIR" \
    --verbose False

  base="$(basename "${AUDIO%.*}")"
  [[ -f "$OUTDIR/$base.vtt" ]] || die "whisper produced no VTT output"
  mv "$OUTDIR/$base.vtt" "$OUTDIR/whisper.vtt"
  VTT="$OUTDIR/whisper.vtt"
  METHOD="local Whisper ($MODEL)"
fi

# ----------------------------------------------- step 3: clean up the VTT ---

step "Building readable transcript"

python3 - "$VTT" "$OUTDIR/transcript.txt" "$INTERVAL" <<'PYEOF'
import re, sys

src, dst, interval = sys.argv[1], sys.argv[2], int(sys.argv[3])

TS = re.compile(
    r'(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*'
    r'(\d{2}):(\d{2}):(\d{2})[.,](\d{3})'
)

def secs(h, m, s, ms):
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0

# --- parse cues -------------------------------------------------------------
cues, start, buf = [], None, []
for line in open(src, encoding='utf-8', errors='replace'):
    line = line.rstrip('\n')
    m = TS.match(line.strip())
    if m:
        if start is not None and buf:
            cues.append((start, buf))
        start, buf = secs(*m.groups()[:4]), []
    elif start is not None:
        if line.strip() and not line.strip().isdigit():
            buf.append(line)
if start is not None and buf:
    cues.append((start, buf))

# --- strip caption markup ---------------------------------------------------
def clean(text):
    text = re.sub(r'<[^>]+>', '', text)            # <c>, <00:00:01.234>, <i>
    text = text.replace('&nbsp;', ' ')
    text = (text.replace('&amp;', '&').replace('&lt;', '<')
                .replace('&gt;', '>').replace('&#39;', "'").replace('&quot;', '"'))
    return re.sub(r'\s+', ' ', text).strip()

# --- de-duplicate rolling captions -----------------------------------------
# YouTube's auto-captions repeat the previous line and append a few new words
# each cue. Overlap the token streams instead of concatenating them, or the
# transcript comes out three times too long and unreadable.
#
# Known trade-off: if a speaker genuinely repeats the tail of one cue at the
# head of the next ("...three percent." / "Three percent is not enough"), the
# repetition is collapsed. Rare, and far cheaper than leaving rolling captions
# untouched, but it means the transcript is not verbatim. Check the audio
# before quoting.
def merge(prev, new, window=40):
    if not prev:
        return new
    limit = min(len(prev), len(new), window)
    for n in range(limit, 0, -1):
        if prev[-n:] == new[:n]:
            return prev + new[n:]
    return prev + new

tokens, marks = [], []          # marks: (token index, seconds)
next_mark = 0.0
for t, lines in cues:
    words = clean(' '.join(lines)).split()
    if not words:
        continue
    before = len(tokens)
    tokens = merge(tokens, words)
    if len(tokens) == before:   # nothing new in this cue
        continue
    if t >= next_mark:
        marks.append((before, t))
        next_mark = t + interval

# --- emit -------------------------------------------------------------------
def hhmmss(t):
    t = int(t)
    return f'{t // 3600:02d}:{(t % 3600) // 60:02d}:{t % 60:02d}'

out, mark_at = [], dict(marks)
para = []
for i, w in enumerate(tokens):
    if i in mark_at and para:
        out.append(' '.join(para))
        para = []
    if i in mark_at:
        out.append(f'\n[{hhmmss(mark_at[i])}]')
    para.append(w)
if para:
    out.append(' '.join(para))

text = '\n'.join(out).strip() + '\n'
open(dst, 'w', encoding='utf-8').write(text)

words = len(tokens)
if words == 0:
    print('  WARNING: no speech found. The source may have an empty or '
          'placeholder caption track — check the raw VTT.')
else:
    print(f'  {words:,} words, ~{max(1, round(words / 150))} min of speech, '
          f'{len(marks)} timestamp anchors')
PYEOF

# ------------------------------------------------------------- provenance ---

{
  echo "Source:     $SOURCE"
  echo "Retrieved:  $(date '+%Y-%m-%d %H:%M %Z')"
  echo "Method:     $METHOD"
  echo "Raw output: $(basename "$VTT")"
  echo
  echo "This transcript is machine-generated and contains errors. Speaker"
  echo "attribution is NOT included — no speaker labels were produced. Before"
  echo "repeating any figure, commitment, or quotation from it, open the"
  echo "recording at the relevant timestamp and confirm it by ear."
} > "$OUTDIR/SOURCE.txt"

if [[ -n "$AUDIO" && "$KEEP_AUDIO" == "0" && "$IS_URL" == "1" ]]; then
  rm -f "$AUDIO"
fi

# ----------------------------------------------------------------- report ---

step "Done"
note "Transcript: $OUTDIR/transcript.txt"
note "Provenance: $OUTDIR/SOURCE.txt"
cat <<'EOF'

Next: attach transcript.txt to a Claude conversation and ask for structure
rather than a summary. Something like —

  "This is a machine transcript of a bargaining session. It has no speaker
   labels. Give me: agenda items in order; each side's proposals with the
   specific numbers and contract language; anything that moved from a
   previously stated position; what was tabled or deferred; and open
   questions at the end. Put the [HH:MM:SS] anchor against every item.
   Where you infer which side is speaking, say so and mark it as inference."

Then use the anchors to spot-check the parts you intend to rely on.
EOF
