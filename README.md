# OpenAI Dictate App

`openai-dictation` projesine dokunmadan, aynı temel akışı tek native macOS app içinde toplar.

## Ne Yapar

- Global hotkey: `Ctrl + Option + Cmd + V`
- İlk basışta kayıt başlatır
- İkinci basışta kaydı durdurur
- Kaydı OpenAI `audio/transcriptions` endpoint'ine gönderir
- Dönen transkripti clipboard'a yazar
- İzin varsa aktif uygulamaya otomatik yapıştırır
- Start / stop / clipboard için sistem sesleri çalar

## Tek App Olarak Neler Değişti

Bu projede dış shell zinciri kaldırıldı. Aşağıdaki işler native Swift ile yapılır:

- hotkey yakalama
- mikrofon kaydı
- state yönetimi
- OpenAI API çağrısı
- JSON response parse
- Keychain API key okuma / yazma
- clipboard write
- auto-paste
- sistem sesleri
- menubar ayarları

Bu nedenle `openai-dictation` klasöründeki `bash`, `curl`, `jq`, `ffmpeg` akışı bu yeni projede kullanılmaz.

## Gereksinimler

- Apple Silicon (`arm64`)
- macOS 26+
- OpenAI API key
- internet erişimi

## İzinler

App ilk kullanımda veya ihtiyaç anında şunları ister / yönlendirir:

- `Microphone`
- `Accessibility`

## API Key

App menubar içinden `Set OpenAI API Key...` ile key'i Keychain'e kaydeder.

Ayrıca şu kaynakları da okuyabilir:

- `OPENAI_API_KEY`
- `WHISPER_API_KEY`
- Keychain service `openai-api-key`
- Keychain service `whisper-api-key`

App'in kendi kayıt service adı:

```text
openai-dictate-app-api-key
```

## Varsayılanlar

- model: `whisper-1`
- language: auto detect
- auto paste: açık
- keep audio files: kapalı
- sound feedback: açık
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

Çıktı:

```text
./build/OpenAI Dictate.dmg
```

DMG içinde şunlar olur:

- `OpenAI Dictate.app`
- `Applications` kısayolu
- `How to Open.txt`

## Menubar Actions

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

Log dosyası:

```text
~/Library/Application Support/OpenAIDictateApp/openai-dictate.log
```
