# NPC Image Display

This repo contains apps for showing NPC or monster images during a tabletop RPG session:

- `NPCImageDisplay`: a native iPad app that runs the display and local HTTP server.
- `MacImageClient`: a native macOS drag-and-drop sender app.
- `mac_client/send_image.py`: a Python Mac client that converts an image to PNG, base64-encodes it, and sends it to the iPad.

Unofficial tabletop RPG utility. Not affiliated with or endorsed by any game publisher.

The intended setup is:

1. Run the iOS app on the iPad.
2. Keep the iPad and Mac on the same Wi-Fi network.
3. Use either the macOS drag-and-drop app or the Python client on the Mac to send an image to the iPad.

The iPad app targets iOS 12.0 and listens on port `8080`.
It also advertises itself with Bonjour as `_npc-image._tcp`.
The Bonjour display name includes the iOS device model and device name, for example `iPad Air 1 - Game Table iPad`.

## API

Show an image:

```bash
POST http://IPAD_IP:8080/image
Content-Type: application/json

{
  "name": "",
  "image": "BASE64_PNG_BYTES",
  "background_color": "#000000"
}
```

The first version uses one full-screen image. A later split-screen version can extend this request with a `slot` field and a layout endpoint without changing the basic Mac-to-iPad flow.

Other endpoints:

- `GET /health` returns JSON status.
- `POST /clear` clears the displayed image. Send `{"background_color":"#202020"}` to clear to a specific color.
- `GET /` returns a tiny status page.

## Mac Drag-And-Drop App

Build the macOS app:

```bash
MacImageClient/build.sh
```

Open the built app:

```bash
open "build/NPC Image Sender.app"
```

Usage:

- Drag image files into the window.
- Drag a folder into the window to load it as the current image set.
- Choose recent image-set folders from the `Image Set` dropdown.
- Choose the destination server from the `Server` dropdown.
- Pick a background color.
- Click an image row to send it to the selected display.
- Click `Clear` to clear the selected display to the selected background color.

The app discovers display servers with Bonjour. The server dropdown updates as servers appear and disappear. Keep each iOS display app open in the foreground.

## Python Mac Client

Install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r mac_client/requirements.txt
```

Send an image:

```bash
python mac_client/send_image.py 192.168.1.42 path/to/image.heic
```

Send with Bonjour discovery:

```bash
python mac_client/send_image.py --discover path/to/image.heic
```

List all discovered iPad displays:

```bash
python mac_client/send_image.py --list-targets
```

Choose a discovered iPad by number, name, model, or IP substring:

```bash
python mac_client/send_image.py --discover --target 2 path/to/image.heic
python mac_client/send_image.py --discover --target "iPad Air 1" path/to/image.heic
python mac_client/send_image.py --discover --target 192.168.1.42 --clear
```

Send an image with a background color:

```bash
python mac_client/send_image.py 192.168.1.42 path/to/image.webp --background-color '#202020'
```

Clear the iPad display:

```bash
python mac_client/send_image.py 192.168.1.42 --clear
```

Clear with Bonjour discovery:

```bash
python mac_client/send_image.py --discover --clear --background-color white
```

Clear to a specific color:

```bash
python mac_client/send_image.py 192.168.1.42 --clear --background-color white
```

Supported inputs depend on your local Pillow build. JPEG, PNG, and WebP are commonly supported. HEIC support is attempted through `pillow-heif` first, then macOS `sips` as a fallback.

Image names are sent only as optional metadata and are not displayed over the image.

## iPad Server App

Open `NPCImageDisplay.xcodeproj` in Xcode, select your iPad as the run destination, and build/run.

The app shows its REST URL on screen. If the iPad sleeps, iOS may suspend the server, so keep the app visible during play.

If a direct IP command times out:

- Confirm the iPad app is open in the foreground.
- Confirm the Mac and iPad are on the same Wi-Fi network.
- Try `python mac_client/send_image.py --discover --clear`.
- If iOS asks for local network access, allow it.

## Notes for iPad Air 1

The iPad Air 1 can run iOS 12. Use the project deployment target `12.0`. You may need an Xcode version that can deploy to your specific device/iOS combination.
