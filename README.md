# 📚 kosyncthing_plus.koplugin - Sync your books across e-ink devices

[![Download Link](https://img.shields.io/badge/Download-Release_Page-blue.svg)](https://github.com/VACE001/kosyncthing_plus.koplugin/releases)

KOSyncthing+ keeps your digital library synchronized. It sends books, reading notes, and progress markers between your e-readers. You manage your files in private. The software requires no external cloud services. It runs a background service inside your KOReader app. This plugin handles Wi-Fi connections, resolves file conflicts, and provides a simple menu for your needs.

## 🛠 Features

*   **Direct Synchronization**: Moves files between your devices without any middleman.
*   **Automatic Wi-Fi Control**: Turns your wireless radio on and off only when needed.
*   **Conflict Handling**: Preserves your latest reading progress if two devices change a file at once.
*   **Private Design**: Keeps your reading data on your local network.
*   **Easy Menu**: Provides a clear interface inside the KOReader environment.

## 📥 Getting Started

Follow these steps to add this functionality to your e-reader.

1.  Visit the [Download Page](https://github.com/VACE001/kosyncthing_plus.koplugin/releases) to obtain the latest version of the plugin.
2.  Locate the file ending in `.koplugin`.
3.  Download this file to your computer.

## ⚙️ Installation

To install this plugin, you must connect your e-reader to your computer.

1.  Plug your device into your computer using a USB cable.
2.  Open your device storage in your file browser.
3.  Find the `koreader` folder.
4.  Enter the `plugins` directory inside the `koreader` folder.
5.  Move the `.koplugin` file you downloaded into this directory.
6.  Safely remove the device from your computer.
7.  Restart your KOReader app.

## 🔌 Configuration

Once you install the plugin, open KOReader to complete the setup.

1.  Open the menu in KOReader.
2.  Select the `Plugin` tab.
3.  Find `KOSyncthing+` in the list and enable it.
4.  Open the KOSyncthing+ settings menu.
5.  Label your device to help you identify it later.
6.  Select the folders you want to sync.
7.  Verify that your Wi-Fi settings allow the app to reach your network.

## 🔄 Using The Plugin

The plugin runs in the background. It checks for changes to your books periodically. If you add a new book to one device, the device sends the file to your other linked readers.

If you change a page on one Kindle or Kobo, the plugin updates the progress on your other devices. If you read a book on two devices at the same time, the conflict resolution tool asks you which version you want to keep.

## 📁 Managing Conflicts

Conflicts happen if you edit the same file on two different devices. The plugin identifies these situations. When a conflict occurs, the KOSyncthing+ menu will alert you. You can choose to keep the local version, the version from the other device, or rename the file to keep both.

## 💻 System Requirements

This plugin works on any device that runs KOReader. 

*   **Operating Systems**: Kindle, Kobo, Android, and Linux-based e-readers.
*   **Network**: A local Wi-Fi network.
*   **Storage**: Enough space to hold your book collection.
*   **Software**: KOReader version 2023.06 or newer.

## 🔧 Troubleshooting

If the sync does not start, check these common issues.

*   **Wi-Fi Status**: Ensure your e-reader connects to your local network. Some e-readers turn off the antenna to save battery.
*   **Folder Location**: Ensure you placed the `.koplugin` file in the correct directory. Restart the device if the plugin does not appear.
*   **Battery Power**: The plugin may pause syncing if your battery level is low. Charge your device and try again.
*   **Device Visibility**: Make sure your devices appear on the same local network. 

## 🛡 Privacy

Your files stay on your devices. This plugin communicates only with the devices you authorize. No third-party servers see your books or your reading habits. Your personal library belongs to you.

## 📝 Frequently Asked Questions

**Does this plugin work on mobile phones?**
Yes, if your phone runs an Android-based version of KOReader.

**Do I need a constant internet connection?**
No. You only need a local network connection to sync your files between your devices.

**Will this delete my files?**
The plugin only creates copies of your files on your other devices. It does not delete files unless you instruct it to remove them from your library.

**Can I sync notes?**
Yes. The plugin preserves your highlights and reading progress.

**Does it require a cloud account?**
No. You do not need to register or sign in to any service.