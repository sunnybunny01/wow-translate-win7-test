# WoWTranslate

<p align="center">
  <strong>Real-time chat translation for World of Warcraft 1.12</strong><br>
  Break the language barrier on multilingual WoW 1.12 servers
</p>

<p align="center">
  <img src="https://img.shields.io/badge/WoW-1.12-blue" alt="WoW 1.12">
  <img src="https://img.shields.io/badge/version-0.12-green" alt="Version 0.12">
  <img src="https://img.shields.io/github/license/sanjaygbhat/wow-translate" alt="License">
</p>

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🌍 **Multi-Language** | Chinese, Japanese, Korean, Russian → English (and reverse) |
| 📚 **WoW Glossary** | 500+ gaming terms translated correctly ("老克" → "Kel'Thuzad", not "Old gram") |
| ⚡ **Instant Cache** | Previously seen translations are instant |
| 💬 **Outgoing Translation** | Type in English, send in Chinese (or other languages) |
| 🔗 **Hyperlink Safe** | Player names, items, and quests stay clickable |
| 🗺️ **Minimap Button** | One-click access to settings, draggable around the minimap |
| 📺 **Channel Filtering** | Choose exactly which channels get translated |
| 💤 **AFK Auto-Pause** | Pausing translation while you're AFK |

---

## 🚀 Quick Start

### 1. Download

**[⬇️ Download Latest Release](../../releases/latest)**

The download includes everything: DLL + Addon in one package.

### 2. Install

Extract and copy to your WoW folder:

```
YourWoWFolder/
├── WoW.exe
├── WoWTranslate.dll        ← From the download
├── dlls.txt                ← Add "WoWTranslate.dll" to this file
└── Interface/
    └── AddOns/
        └── WoWTranslate/   ← From the download
```

> **Note:** If `dlls.txt` doesn't exist, create it and add `WoWTranslate.dll` on the first line.

**Done!** A minimap button (scroll icon) appears — click it to open settings. Chat messages will now appear translated.

---

## 📖 Commands

| Command | Description |
|---------|-------------|
| `/wt show` | Open configuration panel |
| `/wt on` / `/wt off` | Enable/disable translation |
| `/wt status` | Show status and credits |
| `/wt test` | Test translation |
| `/wt outgoing on` | Enable outgoing translation |
| `/wt clearcache` | Clear translation cache |

---

## 💰 Pricing

| Rate | Details |
|------|---------|
| **$30 / million characters** | ~0.003¢ per character |
| **Cache hits are FREE** | Repeated messages cost nothing |
| **Typical usage** | $1-3/month for active players |

Check your balance anytime with `/wt status` or `/wt show`.

---

## 🔧 How It Works

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Glossary   │ →  │    Cache    │ →  │  Translate  │
│  (instant)  │    │   (free)    │    │ (also free) |
└─────────────┘    └─────────────┘    └─────────────┘
```

1. **Glossary** — WoW terms translated instantly (raids, bosses, slang)
2. **Cache** — Seen before? Instant and free
3. **Google Translate**

---

## 🎮 Language Settings

Open settings with `/wt show`:

- **Incoming**: What language to translate FROM (Chinese, Japanese, Korean, Russian)
- **Outgoing**: Enable translation for Say, Party, Guild, Whisper, etc.
- **Channel Filtering**: Toggle individual channels (Say, Yell, Whisper, Party, Guild, Raid, Battleground, World/Local) for both incoming and outgoing
- **AFK Pause**: Translation pauses while AFK (on by default, configurable)

---

## ❓ Troubleshooting

| Problem | Solution |
|---------|----------|
| DLL not loading | Ensure `WoWTranslate.dll` is next to `WoW.exe` and listed in `dlls.txt` |
| No translations | Run `/wt status` to check DLL loaded, then `/wt test 你好` |
| Launcher issues | Run `WoW.exe` directly instead of through a launcher |

---

## 🛠️ Building from Source

<details>
<summary>For contributors</summary>

**Requirements:** Windows, Visual Studio 2022, CMake 3.20+

```bash
cd dll && mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A Win32
cmake --build . --config Release
```

Output: `dll/build/bin/Release/WoWTranslate.dll`

</details>

---

## 📄 License

MIT License

---

<p align="center">
  <sub>Made for the WoW 1.12 community</sub>
</p>
