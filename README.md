# OpenAI Dictate App

This project packages the same core dictation flow as `openai-dictation` into a single native macOS app without modifying the original project.

## Features

- Global hotkey: `Ctrl + Option + Cmd + V`
- Starts recording on the first press
- Stops recording on the second press
- Sends the recording to the OpenAI `audio/transcriptions` endpoint
- Writes the returned transcript to the clipboard
- Automatically pastes into the active app when permissions allow it
- Plays system sounds for start, stop, and clipboard events

## Requirements

- Apple Silicon (`arm64`)
- macOS 26+
- OpenAI API key
- Internet access

## Permissions

On first use, or when needed, the app will request or guide you to grant:

- `Microphone`
- `Accessibility`

## API Key

You can save the API key from the menu bar app using `Set OpenAI API Key...`.

The app can also read from these sources:

- `OPENAI_API_KEY`
- `WHISPER_API_KEY`
- Keychain service `openai-api-key`
- Keychain service `whisper-api-key`

The app's own Keychain service name is:

```text
openai-dictate-app-api-key
```

## Defaults

- model: `whisper-1`
- language: auto detect
- auto paste: enabled
- keep audio files: disabled
- sound feedback: enabled
- start sound: `Glass`
- stop sound: `Glass`
- clipboard sound: `Blow`

## Build App

```zsh
./build-app.zsh
```

## Run App

```zsh
open -n -g "./build/OpenAI Dictate.app"
```

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

```text
~/Library/Application Support/OpenAIDictateApp
```

Log file:

```text
~/Library/Application Support/OpenAIDictateApp/openai-dictate.log
```
