# OpenAI Dictate

`OpenAI Dictate` is a small native macOS menu bar app for voice dictation.
It records your voice, sends it to OpenAI for transcription, copies the result to the clipboard, and can paste it into the app you were using.

## What It Is For

- Dictating into chats, notes, documents, and text fields
- Turning short voice recordings into text quickly
- Using one global shortcut instead of switching between apps

## Quick Start

1. Build the app.

```zsh
./build-app.zsh
```

2. Open the app.

```zsh
open -n -g "./build/OpenAI Dictate.app"
```

3. Click the `OD` menu bar icon.
4. Select `Set OpenAI API Key...` and save your key.
5. Allow `Microphone` and `Accessibility` when macOS asks.
6. Press `Ctrl + Option + Cmd + V` to start recording.
7. Press the same shortcut again to stop and transcribe.

## How It Works

1. First hotkey press starts recording.
2. Second hotkey press stops recording.
3. The transcript is copied to the clipboard.
4. If Accessibility permission is available, the transcript is also pasted into the active app.

## Requirements

- Apple Silicon (`arm64`)
- macOS 26+
- OpenAI API key
- Internet access

## Permissions

The app needs these permissions:

- `Microphone` to record audio
- `Accessibility` to auto-paste into the active app

## API Key

The easiest setup is to save the key from the menu bar app with `Set OpenAI API Key...`.

The app can also read from:

- `OPENAI_API_KEY`
- `WHISPER_API_KEY`
- Keychain service `openai-api-key`
- Keychain service `whisper-api-key`

Its own Keychain service name is:

```text
openai-dictate-app-api-key
```

## Defaults

- Model: `whisper-1`
- Language: auto detect
- Auto paste: enabled
- Keep audio files: disabled
- Sound feedback: enabled
- Start sound: `Glass`
- Stop sound: `Glass`
- Clipboard sound: `Blow`

## Build DMG

```zsh
./build-dmg.zsh
```

Output:

```text
./build/OpenAI Dictate.dmg
```

The DMG contains:

- `OpenAI Dictate.app`
- `Applications` shortcut
- `How to Open.txt`

## Menu Bar Actions

- `Toggle Dictation`
- `Set OpenAI API Key...`
- `Clear Stored API Key`
- `Set Language...`
- `Set Model...`
- `Auto Paste`
- `Keep Audio Files`
- `Sound Feedback`
- `Open Data Folder`
- `Open Microphone Settings`
- `Open Accessibility Settings`

## Runtime Files

Data folder:

```text
~/Library/Application Support/OpenAIDictateApp
```

Log file:

```text
~/Library/Application Support/OpenAIDictateApp/openai-dictate.log
```
