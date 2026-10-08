# MeetingNotes

A free, open-source, lightweight macOS menu-bar app that records a Zoom meeting **locally** and turns
it into a short summary plus long, detailed notes, using your own Claude, OpenAI, Gemini or Mistral API key.

It does not join the call as a bot and adds nothing to the meeting, so Zoom does not notify other
participants. Recording laws differ by country and company. See [Responsible use](#responsible-use).

| Menu bar | AI notes settings | Transcription settings |
|---|---|---|
| <img src="docs/menu.png" width="280" alt="Menu-bar popover with Start recording, quick switches and recent meetings"> | <img src="docs/settings-ai.png" width="300" alt="Settings, AI notes tab: provider, API key and model"> | <img src="docs/settings-transcription.png" width="300" alt="Settings, Transcription tab: local whisper.cpp with model found"> |

**Contents:** [Features](#features) · [Example output](#example-output) · [How it works](#how-it-works) ·
[Why two AI models](#why-two-different-ai-models) · [Whisper & the model file](#transcription-whisper-ggml-and-large-v3-turbo-q5_0) ·
[Project structure](#project-structure) · [Setup on a new Mac](#setting-up-on-a-new-mac) ·
[Troubleshooting](#troubleshooting) · [Privacy](#privacy)

## Features

- **Records locally:** Zoom's audio (the other participants) through ScreenCaptureKit, and your voice
  through the microphone. Nothing leaves your Mac except the transcript sent to the AI provider you pick.
- **British and Indian English:** Whisper transcription is fixed to English with an accent and
  vocabulary hint, and the AI is told to fix obvious mishearings from context.
- **Who said what:** in Zoom's Gallery view the active speaker gets a green border. About once a second
  the app finds that border in the Zoom window and reads the name label with on-device OCR (Apple
  Vision), so the transcript says `Priya Sharma:` instead of `Others:`. Frames are never saved.
- **Audio-only fallback:** if Zoom is minimised or on another Space, recording carries on, those lines
  are labelled `Not recognised`, and speaker detection resumes on its own when the window is back.
- **Bring your own AI:** Claude (Anthropic), ChatGPT (OpenAI), Gemini (Google) or Mistral. The model list is fetched live from the
  provider, so new models appear without an app update. Keys are kept in the macOS Keychain.
- **Free transcription:** offline `whisper.cpp`, or the OpenAI Whisper API if you prefer.
- **Hands-free:** optional auto-record when a Zoom meeting starts, launch at login, and a macOS
  notification when the notes are ready.

## Example output

Each meeting gets a folder in `~/Documents/MeetingNotes/<date time>/`. The example below is fictional.

`transcript.md`

```text
[00:04] Alex: Morning all. Quick one today, the release plan and the login bug.

[00:11] Priya Sharma: So the fix is merged, but QA found one more edge case with expired sessions.

[00:24] James Carter: Can we still ship on Thursday, or do we push to Monday?

[00:31] Not recognised: I think Thursday is fine if QA signs off by Wednesday evening.
```

`notes.md`

```markdown
## Summary
- Login bug fix is merged; one edge case with expired sessions remains.
- Release stays on Thursday if QA signs off by Wednesday evening.

## Decisions
- Keep the Thursday release date, conditional on QA sign-off.

## Action items
- [ ] Fix the expired-session edge case (Priya Sharma, Wednesday)
- [ ] QA sign-off on the release build (QA team, Wednesday evening)

## Open questions
- Who owns the rollback plan if sign-off slips?

## Detailed notes
### Login bug
Priya confirmed the fix is merged. QA reproduced one more case where an expired session ...

### Release plan
James asked whether Thursday is still realistic ...
```

## How it works

### The flow

```text
                ┌──────────────── during the meeting ────────────────┐
 Zoom audio ────┤ ScreenCaptureKit ─► 16 kHz mono WAV, 10-min chunks │──┐
 Your mic ──────┤ AVAudioEngine    ─► 16 kHz mono WAV, 10-min chunks │──┤
 Zoom window ───┤ 1 frame/sec ─► green border ─► OCR name ─► timeline│──┼──┐
                └────────────────────────────────────────────────────┘  │  │
                ┌──────────────── after you press Stop ──────────────┐  │  │
                │ 1. Speech → text   whisper.cpp (local) or Whisper API ◄─┘  │
                │ 2. Who said it     mic lines = you, Zoom lines = name ◄────┘
                │                    from the timeline, else "Not recognised"
                │ 3. Save            transcript.md
                │ 4. Text → notes    your AI provider (Claude/OpenAI/Gemini/Mistral)
                │ 5. Save            notes.md, delete the audio, notify you
                └────────────────────────────────────────────────────┘
```

1. **Start.** You press *Start recording*, or *Auto-record* sees Zoom's `CptHost` helper process
   (it only exists while you are in a meeting) and starts for you. It stops when the process goes away.
2. **Capture.** Two separate audio tracks are recorded: Zoom's own audio (everyone else) through
   ScreenCaptureKit, filtered to the Zoom app only, and your microphone. Keeping them separate means
   every line from the mic is you, with no guessing. Both are converted on the fly to 16 kHz mono,
   the format Whisper expects, and written in 10-minute WAV chunks so a long meeting never builds one
   huge file (and each chunk stays under the Whisper API's 25 MB upload limit).
3. **Speaker detection** runs in parallel: about once a second the Zoom window is checked for the
   green active-speaker border and the name in that tile is read with Apple's on-device OCR. This
   produces a timeline like `00:31 Priya Sharma, 00:32 Priya Sharma, 00:40 James Carter`. Frames are
   analysed in memory and thrown away.
4. **Transcribe.** After you stop, each chunk goes through Whisper, which returns text with start
   and end times. Chunk offsets turn those into meeting times.
5. **Name the lines.** Mic lines get your name. For each Zoom line the app looks up who the timeline
   says was highlighted during those seconds; if nobody was (Zoom minimised, Speaker view), the line
   is `Not recognised`. Lines are sorted by time and consecutive lines by the same person merged.
6. **Write notes.** The transcript, the speaker list and a fixed instruction prompt go to the AI
   provider you picked. It returns the Summary, Decisions, Action items, Open questions and Detailed
   notes as Markdown.
7. **Clean up.** `transcript.md` and `notes.md` are saved, the WAV files are deleted, and you get a
   notification. If any step fails the audio is kept so **Retry** can run steps 4–7 again.

### Why two different AI models?

Turning a meeting into notes is two different jobs, and no single small model does both well:

| | Speech-to-text (Whisper) | Notes (Claude / GPT / Gemini / Mistral) |
|---|---|---|
| Input | Audio | Text (the transcript) |
| Output | What was said, word for word, with timestamps | What it *means*: summary, decisions, owners |
| Understands the meeting? | No. It only hears sounds and writes words | Yes. It reads the whole meeting at once |
| Runs | On your Mac, free (or OpenAI's API) | In the provider's cloud, with your API key |

**Why your own API key?** Writing good notes needs a large language model: one that can read an
hour of conversation, fix words Whisper misheard ("cube control" → "kubectl") from context, notice
that a decision was made 20 minutes after it was first discussed, and attribute action items to the
right person. Models that do this well are far too big to run on a laptop, so the app calls one
through the provider's API. There is no MeetingNotes server in between: the transcript goes straight
from your Mac to the provider you chose, under your own account. That is why you bring the key, pay
the provider directly (a one-hour meeting is roughly 10–15k words, typically a few cents to a few tens
of cents depending on the model), and can switch providers or models at any time. Keys are stored in
the macOS Keychain. Turn *Write AI notes* off and nothing is sent anywhere; you just get the transcript.

### Transcription: Whisper, GGML and `large-v3-turbo-q5_0`

**Whisper** is OpenAI's open-source speech-recognition model. It is a transformer trained on a very
large amount of real-world audio in many accents, which is why it copes well with British and Indian
English. It works on 30-second windows: the audio is turned into a spectrogram (a picture of which
frequencies are loud at each moment), an *encoder* turns that into a representation of the sounds,
and a *decoder* writes the text one token at a time, with timestamps.

**whisper.cpp** is a C/C++ re-implementation of Whisper that runs entirely on your Mac (and can use
the Apple Silicon GPU). No audio leaves the machine and there is no per-minute cost. The app runs
it as a command-line tool (`whisper-cli`) on each chunk.

**GGML** is the tensor library behind whisper.cpp, and `.bin` files in its format hold the model's
weights. That is why the model is a separate download from `brew install whisper-cpp`: the program
and the trained weights are two different things.

**What the file name means:** `ggml-large-v3-turbo-q5_0.bin`

| Part | Meaning | Why this choice |
|---|---|---|
| `large-v3` | Whisper's largest, most accurate model generation | Best accuracy on accents and technical words |
| `turbo` | large-v3 with the decoder cut from 32 layers to 4 | Several times faster, with only a small accuracy loss |
| `q5_0` | Weights quantised from 16-bit to about 5-bit numbers | ~550 MB instead of ~1.6 GB, less memory, faster, near-identical output |

Together this gives close to the best Whisper accuracy at a size and speed that suits a laptop. On
Apple Silicon it transcribes much faster than real time. On slower machines a smaller model trades
accuracy for speed; download it from the
[whisper.cpp model list](https://huggingface.co/ggerganov/whisper.cpp/tree/main) and set its path
in Settings → Transcription:

| Model file | Size | When to use |
|---|---|---|
| `ggml-large-v3-turbo-q5_0.bin` | ~550 MB | Default: best balance of accuracy and speed |
| `ggml-small.en-q5_1.bin` | ~190 MB | Older or Intel Macs; less accurate on strong accents |
| `ggml-large-v3.bin` | ~3 GB | Maximum accuracy, much slower |

**Two settings make it better for this use:**

- **Language is fixed to English.** Otherwise Whisper may detect Indian English as Hindi and write
  the wrong script or translate.
- **A prompt hint** ("a work meeting in British and Indian English, with product, engineering and
  business terms") is passed as Whisper's initial prompt, which nudges its spelling and vocabulary.

The **OpenAI Whisper API** option runs the same kind of model on OpenAI's servers instead: nothing
to install, but the audio is uploaded and billed per minute, and it needs an OpenAI key.

## Project structure

```text
mac-app/
├── LICENSE                      MIT
├── README.md                    List of apps in this repo
└── meeting-notes/
    ├── Package.swift            Swift Package: macOS 13+, no third-party dependencies
    ├── Resources/Info.plist     Bundle id, menu-bar-only app (no Dock icon), microphone prompt text
    ├── scripts/build_app.sh     Builds a release binary, wraps it into MeetingNotes.app, signs it ad hoc
    ├── docs/                    Screenshots used in this README
    └── Sources/MeetingNotes/
        ├── MeetingNotesApp.swift   UI: menu-bar popover and the Settings window (General, AI notes, Transcription)
        ├── AppModel.swift          State (idle → recording → processing → done/failed), Zoom auto-detect,
        │                           runs the pipeline, recent meetings
        ├── Recorder.swift          ScreenCaptureKit (Zoom audio + frames), microphone, 16 kHz WAV chunk writer
        ├── SpeakerDetector.swift   Green-border detection, Vision OCR, Zoom-visible check, speaker timeline
        ├── Transcriber.swift       whisper.cpp / Whisper API calls, timestamps, transcript formatting
        ├── LLM.swift               Notes prompt; Anthropic API and OpenAI-compatible API (OpenAI, Gemini,
        │                           Mistral); live model lists
        ├── Support.swift           Providers, preferences, Keychain, HTTP helper
        └── System.swift            Launch at login, macOS notifications
```

Built with Apple frameworks only: SwiftUI, ScreenCaptureKit, AVFoundation, Vision, ServiceManagement,
UserNotifications and Security (Keychain).

## Setting up on a new Mac

Needs macOS 13 (Ventura) or newer, on Apple Silicon or Intel. Takes about 10 minutes, most of it downloads.

### 1. Install the tools (one time)

```bash
# Swift compiler (skip if Xcode is installed; `swift --version` should work afterwards)
xcode-select --install

# Homebrew (skip if `brew --version` already works)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Free, offline speech-to-text
brew install whisper-cpp
```

### 2. Download the speech model (one time, ~550 MB)

```bash
mkdir -p ~/Library/Application\ Support/MeetingNotes
curl -L -o ~/Library/Application\ Support/MeetingNotes/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

Skip steps 1–2 for whisper if you will use the **OpenAI Whisper API** for transcription instead
(Settings → Transcription); that uploads the audio to OpenAI and needs an OpenAI key.

### 3. Get the code and build the app

```bash
git clone https://github.com/sunny-github69/mac-app.git
cd mac-app/meeting-notes
./scripts/build_app.sh                      # creates build/MeetingNotes.app
cp -R build/MeetingNotes.app /Applications/ # needed for "Launch at login"
open /Applications/MeetingNotes.app
```

A waveform icon appears in the menu bar (top right). There is no Dock icon; that is expected.

> Keep the repo out of iCloud Drive / OneDrive / Dropbox folders: the build creates thousands of
> files in `.build/` and the sync client will slow it down.

### 4. Configure

Click the menu-bar icon, then the ⚙︎ button in the top-right corner of the popover:

- **AI notes**: pick a provider and paste its API key. The **Get a key** link opens the right page:
  [Anthropic](https://console.anthropic.com/settings/keys), [OpenAI](https://platform.openai.com/api-keys),
  [Google AI Studio](https://aistudio.google.com/app/apikey) or [Mistral](https://console.mistral.ai/api-keys).
  Each provider's key is saved separately, so you can switch between them. It is checked live ("Key works · N models")
  and the model list loads; pick a model. Keys are stored in the macOS Keychain, never in files.
  Turn AI notes off to save only the transcript.
- **General**: *Launch at login*, *Auto-record when a Zoom meeting starts*, your name (used instead
  of "You" in the transcript), and *Identify who is speaking*.
- **Transcription**: local whisper.cpp (shows "Model found" if step 2 worked) or the OpenAI API.

The three main switches (auto-record, speakers, AI notes) are also in the menu-bar popover.

### 5. Grant permissions and do a test recording

1. Start a Zoom meeting (alone is fine) and switch to **Gallery view**. Use headphones.
2. Press **Start recording**. macOS asks for:

   - **Microphone** → Allow.
   - **Screen & System Audio Recording** → open System Settings → Privacy & Security → enable
     *MeetingNotes*. macOS may ask you to quit and reopen the app; do so and start again.
3. While recording, the popover shows a timer and who is speaking, e.g. "Priya Sharma is speaking".
   Minimise Zoom and it switches to "Zoom not visible – notes from audio only".
4. Press **Stop & write notes**. When the notification arrives, click it (or **Open**) to read the notes.

To test speaker names, join the same meeting from a phone and talk from there.

### Daily use

- **Manual:** menu-bar icon → **Start recording** → **Stop & write notes**.
- **Automatic:** turn on **Auto-record Zoom meetings**. Recording starts when you join a meeting and
  the notes are written when you leave. Pressing Stop mid-meeting stops it for that meeting.
- Past meetings are listed under **Recent** in the popover; **Open notes folder** shows all of them.

### Updating

```bash
cd mac-app/meeting-notes
git pull
pkill -x MeetingNotes                       # quit the running copy (ignore "no process found")
./scripts/build_app.sh
rm -rf /Applications/MeetingNotes.app
cp -R build/MeetingNotes.app /Applications/
open /Applications/MeetingNotes.app
```

The app is ad-hoc signed, so macOS treats each build as a new app: if recording fails after an update,
remove *MeetingNotes* from Privacy & Security → Screen & System Audio Recording and Microphone, and
allow it again. Settings and API keys are kept.

### Troubleshooting

| Problem | Fix |
|---|---|
| `cd: no such file or directory` | Run the commands from the folder you cloned into (`pwd` shows where you are). |
| `swift: command not found` | `xcode-select --install`, then open a new terminal. |
| "whisper.cpp not found" | `brew install whisper-cpp` |
| `brew` says "You are using macOS on Intel x86_64" on an Apple Silicon Mac | You have an old Intel Homebrew in `/usr/local` (often migrated from an older Mac). Install the native one in `/opt/homebrew` (step 1), run `echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile`, open a new terminal, check `which brew` shows `/opt/homebrew/bin/brew`, then install whisper-cpp again. |
| "Whisper model not found" | Redo step 2, or fix the path in Settings → Transcription. |
| Notes have no "Others" lines | Screen & System Audio Recording permission is missing; grant it and reopen the app. |
| Every line is "Not recognised" | Use Zoom's Gallery view and keep the Zoom window visible. |
| "Couldn't change login item" | Move the app to `/Applications` first. |
| API error | Check the key and the account's credit in the provider's console. |

### Uninstall

```bash
rm -rf /Applications/MeetingNotes.app ~/Library/Application\ Support/MeetingNotes
defaults delete com.local.meetingnotes
```
Meeting notes in `~/Documents/MeetingNotes` are left alone.

## Limitations
- Speaker names need Gallery view and the Zoom window visible (not minimised). Speaker view has no
  green border, so those lines fall back to `Not recognised`.
- Start Zoom before recording: then only Zoom's audio is captured. Otherwise it falls back to all system audio
  and speaker names are off.
- Use headphones, otherwise Zoom audio leaks into your mic and gets transcribed twice.
- Speaker names come from OCR of Zoom's UI and can lag by a line, or misread an unusual name.
- Zoom must be on the main display.

## Responsible use

You are responsible for how you use this app. Recording laws differ by country and state (some require
every participant's consent), and many employers have recording policies. Check both before recording
a meeting without telling people.

## Privacy

- Audio and Zoom frames are processed on your Mac. Frames are never written to disk.
- The transcript is sent only to the AI provider you choose (and, if you pick the OpenAI Whisper API,
  the audio is uploaded to OpenAI).
- API keys are stored in the macOS Keychain, not in files or in this repository.

## License

[MIT](../LICENSE)
