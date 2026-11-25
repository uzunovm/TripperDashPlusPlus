# Install TripperDash++ on your own iPhone (from source)

This runbook builds the **`rework`** branch of the fork `uzunovm/TripperDashPlusPlus` (vector map + UI redesign). The `rework` build adds no entitlements or permissions beyond `main` and installs it on your iPhone. `main` on the fork mirrors upstream `kolaCZek/TripperDashPlusPlus`.

Time: about 30 minutes the first time, most of it signing. After that, a rebuild takes 2 to 3 minutes.

---

## 1. Prerequisites

1. **Mac**: macOS 15 or newer, **Xcode 26.5 or newer** (App Store or developer.apple.com). Open Xcode once so it installs its components.
2. **iPhone**: **iPhone 13 or newer**, **iOS 18.6 or newer**. Older iPhones lack the hardware H.264 encoder and dual-band Wi-Fi the app needs.
3. **Connection**: a USB cable for the first run. After that you can use Wi-Fi: in Xcode, **Window → Devices and Simulators**, select the iPhone, tick **Connect via network**.
4. **Apple Developer account**: a **paid Apple Developer Program** membership (99 USD/year), signed in under **Xcode → Settings… → Accounts**.

### Why the paid program is needed

`TripperDashPP/TripperDashPP.entitlements` requests two entitlements:

| Entitlement | Used for |
|---|---|
| `com.apple.developer.networking.HotspotConfiguration` | `WiFiJoiner.swift` joins the bike's `RE_XXXX_XXXXXX` Wi-Fi from inside the app |
| `com.apple.developer.networking.wifi-info` | `NEHotspotNetwork.fetchCurrent` reads the current SSID (connect preflight). Without it, it always returns nil |

A free **Personal Team** cannot sign apps with these entitlements. Xcode stops with an error like *"Personal development teams … do not support the Hotspot Configuration capability"*.

### Free Personal Team workaround (local only, NEVER commit)

You can still build if you strip the two entitlements **on your machine only**. Effects:

- Adding a bike no longer joins its Wi-Fi. Join `RE_XXXX_XXXXXX` by hand in iOS **Settings → Wi-Fi** before each ride.
- The SSID preflight cannot read the network name, so it is skipped. Connecting still works once the phone is on the bike's Wi-Fi.
- The app expires after **7 days**. Rebuild from Xcode to renew it.
- A free team can register at most 10 App IDs per 7 days. This project uses 4 (app, Share, Widgets, Tests).

Steps:

1. Replace the entitlements file with an empty one:

   ```bash
   cat > TripperDashPP/TripperDashPP.entitlements <<'EOF'
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict/>
   </plist>
   EOF
   ```

2. Tell git to ignore your local change, so it never ends up in a commit:

   ```bash
   git update-index --skip-worktree TripperDashPP/TripperDashPP.entitlements
   ```

3. To undo later (before switching to a paid team):

   ```bash
   git update-index --no-skip-worktree TripperDashPP/TripperDashPP.entitlements
   ```

   ```bash
   git checkout -- TripperDashPP/TripperDashPP.entitlements
   ```

---

## 2. Get the code

1. Clone the fork:

   ```bash
   git clone https://github.com/uzunovm/TripperDashPlusPlus.git
   ```

   ```bash
   cd TripperDashPlusPlus
   ```

2. Check out the integration branch `rework`:

   ```bash
   git checkout rework
   ```

3. Later, to get the newest `rework`:

   ```bash
   git pull
   ```

The app has no third-party dependencies, API keys or secrets. Nothing else to download.

---

## 3. Signing

The project ships signed for the upstream author's team (`DEVELOPMENT_TEAM = KGL8J75LNN`) and bundle IDs under `eu.kolaczek.TripperDashPP`. You must change both, or Xcode can't create provisioning profiles.

1. Open the project:

   ```bash
   open TripperDashPP/TripperDashPP.xcodeproj
   ```

2. In the left sidebar, click the blue **TripperDashPP** project icon. The editor lists 4 targets.

3. Change the bundle IDs to your own prefix. The extensions must **start with the app's bundle ID**, or Xcode refuses to embed them (*"Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier"*). Replace `eu.yourname` with something unique, e.g. `com.uzunovm`:

   | Target | Original bundle ID | Change to |
   |---|---|---|
   | **TripperDashPP** (app) | `eu.kolaczek.TripperDashPP` | `eu.yourname.TripperDashPP` |
   | **TripperDashShare** (Share Extension) | `eu.kolaczek.TripperDashPP.TripperDashShare` | `eu.yourname.TripperDashPP.TripperDashShare` |
   | **TripperDashWidgets** (Widgets + Live Activity) | `eu.kolaczek.TripperDashPP.TripperDashWidgets` | `eu.yourname.TripperDashPP.TripperDashWidgets` |
   | **TripperDashPPTests** (unit tests) | `eu.kolaczek.TripperDashPPTests` | `eu.yourname.TripperDashPPTests` |

   Either edit each in **target → Signing & Capabilities → Bundle Identifier** (for **both** Debug and Release; the tab shows *All* by default, which covers both), or replace them all at once from the repo root (quit Xcode first):

   ```bash
   sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = eu\.kolaczek\./PRODUCT_BUNDLE_IDENTIFIER = eu.yourname./' TripperDashPP/TripperDashPP.xcodeproj/project.pbxproj
   ```

4. For **each of the 4 targets**: **target → Signing & Capabilities**:
   1. Keep **Automatically manage signing** ticked (the project uses `CODE_SIGN_STYLE = Automatic`).
   2. Set **Team** to your paid team (or your Personal Team, with the workaround above).
   3. Wait for the *Provisioning Profile: Xcode Managed Profile* line. A red error here is covered in [Troubleshooting](#7-troubleshooting).

   On the **TripperDashPP** target you should see the capabilities **Hotspot Configuration** and **Access Wi-Fi Information** (plus **Background Modes**: Location updates, Audio). Leave them.

Nothing else needs to match:

- **No App Groups**: the app and the extensions share no container, so there is no `group.` ID to change.
- The URL type name `eu.kolaczek.TripperDashPP.deeplink` (in `TripperDashPP-Info.plist`) and the `Logger` subsystems are labels only. Leave them; **Export log** filters on the `eu.kolaczek` subsystem prefix.
- The tip product IDs in `UI/SupportView.swift` (`eu.kolaczek.TripperDashPP.tip.*`) belong to the upstream App Store record. With your bundle ID, **Settings → Support TripperDash++** shows no tips. Expected.

**Keep the signing edits local.** They touch `project.pbxproj`, which upstream also edits. Don't commit them to `rework` or `main`, or every upstream sync conflicts. Before `git pull`, set them aside and re-apply:

```bash
git stash push -m my-signing
```

```bash
git pull
```

```bash
git stash pop
```

---

## 4. On the iPhone

### 4.1 Developer Mode (iOS 16+, needed once)

1. Connect the iPhone to the Mac and tap **Trust** on the iPhone's *"Trust This Computer?"* prompt, then enter the passcode.
2. iPhone: **Settings → Privacy & Security → Developer Mode** → on.
   - The row only appears after the iPhone has been connected to Xcode once (or after a first Run attempt). See [Troubleshooting](#developer-mode-is-missing).
3. The iPhone restarts. After the restart, tap **Turn On** and enter the passcode.

### 4.2 Trust the developer certificate

Needed with a Personal Team, or the first time a paid-team build is installed if iOS asks:

1. iPhone: **Settings → General → VPN & Device Management**.
2. Under **Developer App**, tap your Apple ID / team → **Trust "…"** → **Trust**.

### 4.3 First-run permissions

iOS asks for each permission the first time the app needs it. To review or grant them all at once, open **Settings → Check permissions** in the app (`UI/PermissionsView.swift`; tap **Set** next to each). The permissions:

| Permission | Choose | Why |
|---|---|---|
| **Location** | **While Using** is enough. Accept **Always** if offered | Bike position, and background updates keep the stream alive with the screen locked (`UIBackgroundModes`: `location`) |
| **Local Network** | **Allow** | UDP to the dash at `192.168.1.1` (and to the fake_dash laptop). Without it nothing reaches the dash |
| **Cellular Data** | iOS **Settings → TripperDash++ → Cellular Data** on | Map tiles, routing, search and weather go over cellular while Wi-Fi is the bike's AP, which has no internet |
| **Apple Music** | Allow (optional) | Dash joystick LEFT/RIGHT skips tracks |
| **Live Activities** | Allow (optional) | Lock Screen / Dynamic Island ride card |

The app sends **no push notifications**, so there is no notification prompt. Incoming calls reach the dash through CallKit, which needs no permission.

When you **add a bike**, iOS also shows *"TripperDash++ wants to join Wi-Fi network RE_…"*. Tap **Join** (paid team only).

---

## 5. Run it

### 5.1 Build & Run from Xcode

1. In the Xcode toolbar, set the scheme to **TripperDashPP** and the destination to **your iPhone** (not a simulator).
2. **Product → Run** (⌘R).
3. The first build takes a few minutes. The app opens on the iPhone and stays installed after you unplug it.

A build from a **paid** team stays valid for up to a year (the provisioning profile's lifetime). Only free-team builds expire after 7 days.

### 5.2 Optional: TestFlight (internal testing)

Use this to install without the Mac nearby, and to get **Export log** in a non-Debug build. Paid team only.

1. In [App Store Connect](https://appstoreconnect.apple.com) → **Apps → + → New App**: platform iOS, your bundle ID from step 3 (`eu.yourname.TripperDashPP`), any unique name and SKU.
2. Xcode: destination **Any iOS Device (arm64)** → **Product → Archive**.
3. In the Organizer: **Distribute App → App Store Connect → Upload**, keep the defaults.
4. Version numbers: Marketing Version (`MARKETING_VERSION`, currently `1.0.5`) and build number (`CURRENT_PROJECT_VERSION`). Each upload of the same version needs a **higher build number**: **TripperDashPP target → General → Identity → Build**.
5. When processing finishes (about 10 to 30 minutes), App Store Connect → your app → **TestFlight → Internal Testing**: create a group and add yourself.
6. On the iPhone, install the **TestFlight** app and install the build from there. Internal builds need no review.

---

## 6. Smoke test before a ride

### 6.1 Quickest: Demo mode (no harness, no bike)

1. In the app: **Settings → Bikes → Demo mode** on.
2. Start a ride or free ride. The dash picture renders on the phone screen. GPS, routing, map and voice are real; nothing goes over Wi-Fi.

This checks the map, routing and the UI redesign. It does not test the dash link.

While in Demo mode, check the `rework` map settings in **Settings → Map**:

- **Map renderer**: **Vector** (new, tiles from `tiles.openfreemap.org`) or **Raster (classic)** (OpenStreetMap). Try both. If the vector map looks wrong, switch to Raster (classic) for the ride.
- **Smooth position**: keeps you on the route line and glides the map between GPS fixes. Turn it off if the position looks laggy or snaps to the wrong road.

Do this once on cellular with Wi-Fi off, so tiles for both renderers download the way they will on the bike.

### 6.2 fake_dash harness (tests the dash link, no bike)

`tools/fake_dash/` is a Docker emulator of the Tripper: K1G control on UDP 2000, RTP video on UDP 5000. It accepts packets the real dash would reject, so it tests plumbing, not protocol correctness.

1. On the Mac (Docker Desktop running), from the repo root:

   ```bash
   make fake-dash-up
   ```

2. Find the Mac's Wi-Fi IP:

   ```bash
   ipconfig getifaddr en0
   ```

3. Point the app at the Mac. The app has no dash-IP setting; it reads the `BikeLink.bikeHost` UserDefaults key (default `192.168.1.1`). Pass it as a launch argument: Xcode **Product → Scheme → Edit Scheme… → Run → Arguments → Arguments Passed On Launch** → **+** → `-BikeLink.bikeHost 192.168.x.y` (the IP from step 2). Then **Run** (⌘R) again. Untick it afterwards, or the app keeps looking for the Mac instead of the bike.
4. In the app: **Settings → Bikes → Add bike**, SSID **`RE_FAKE_260616`** (the SSID fake_dash expects).
5. **Wi-Fi name caveat.** Before connecting, the app checks that the phone's current Wi-Fi name equals the bike's SSID, and fails with a "not on the dash network" error if it doesn't. On your home Wi-Fi the names differ. Pick one:
   - **Same network, renamed**: put phone and Mac on a Wi-Fi network named `RE_FAKE_260616` (a spare travel router, or macOS **System Settings → General → Sharing → Internet Sharing** sharing Ethernet over Wi-Fi with that network name).
   - **Free-team build**: the SSID can't be read without the Wi-Fi Info entitlement, so the check is skipped and your home Wi-Fi works.
   - **Simulator instead of the phone**: set the launch argument to `-BikeLink.bikeHost 127.0.0.1` and run on an iPhone simulator. Docker forwards the ports.
6. Expect a ~5 s pause before the handshake if the network is not `192.168.1.x` (the app waits for a dash-subnet address, then proceeds).
7. Connect and start a ride. Watch the harness:

   ```bash
   make fake-dash-logs
   ```

   Look for `AUTH ← … session key OK`, then RTP frames. Captured video lands in `tools/fake_dash/captures/dash_capture_<timestamp>.h264`:

   ```bash
   open tools/fake_dash/captures/
   ```

8. Send a joystick press to the phone:

   ```bash
   make fake-dash-btn-click
   ```

9. Stop the harness:

   ```bash
   make fake-dash-down
   ```

### 6.3 Real dash

1. Remove the `-BikeLink.bikeHost` launch argument (step 6.2.3), rebuild, and turn **Demo mode** off.
2. Ignition on. On the Tripper, open its phone-pairing screen and note the Wi-Fi name, `RE_XXXX_XXXXXX` (e.g. `RE_0W12_345678`).
3. In the app: **Settings → Bikes → Add bike** → **Wi-Fi network (SSID)** = that name, optional **Name** → add. Tap **Join** on the iOS Wi-Fi prompt.
4. On the main screen, tap **Connect to dash** (or **Connect** in the bike list). The dash switches to the phone picture.
5. Lock the phone and check the dash keeps updating for a minute before you ride.

---

## 7. Troubleshooting

### Signing and provisioning errors

| Error (Signing & Capabilities tab, or build log) | Fix |
|---|---|
| *No account for team "KGL8J75LNN"* / *No signing certificate* | The team is still upstream's. Set **Team** on all 4 targets (step 3.4). |
| *Failed to register bundle identifier* / *The app identifier "eu.kolaczek.TripperDashPP" cannot be registered to your development team* | That bundle ID belongs to someone else. Change all 4 (step 3.3). |
| *Embedded binary's bundle identifier is not prefixed with the parent app's bundle identifier* | A Share/Widgets bundle ID doesn't start with the app's. Fix the prefix. |
| *Personal development teams … do not support the Hotspot Configuration capability* (or *Access WiFi Information*) | Free team. Join the paid program, or use the [local workaround](#free-personal-team-workaround-local-only-never-commit). |
| *Provisioning profile doesn't include the … entitlement* | Paid team, but the profile is stale. Untick and re-tick **Automatically manage signing**, or delete `~/Library/Developer/Xcode/UserData/Provisioning Profiles/*` and build again. |
| *Communication with Apple failed* / *Your team has no devices* | Connect the iPhone by cable with Developer Mode on, select it as destination, build again so Xcode registers it. |
| *Maximum number of apps for free development profiles has been reached* | Free teams allow 3 sideloaded apps per device. Delete another sideloaded app. |

### "Untrusted Developer"

The app icon is on the Home Screen but launching shows *"Untrusted Developer"*. Do step [4.2](#42-trust-the-developer-certificate) (**Settings → General → VPN & Device Management → Trust**). If no team appears there, launch the app once from Xcode first.

### Developer Mode is missing

**Settings → Privacy & Security → Developer Mode** only appears after the iPhone has been connected to Xcode. Connect by cable, trust the Mac, open **Window → Devices and Simulators** in Xcode (or try a Run), then check again. A MDM-managed (work) iPhone may block it entirely.

### App stops opening after a week

Only **free Personal Team** builds expire after **7 days**. Reconnect and **Run** from Xcode again. Paid-team development builds last as long as their profile (up to a year); TestFlight builds last 90 days.

### "Could not launch" / "device is locked"

Unlock the iPhone and keep it unlocked while Xcode installs and launches.

### Map is blank, routing fails

The phone is on the bike's Wi-Fi, which has no internet, and cellular is off for the app. Turn on iOS **Settings → TripperDash++ → Cellular Data** (and **Settings → Cellular → Cellular Data**).

If only the **Vector** renderer is blank, `tiles.openfreemap.org` is unreachable or slow. Switch **Settings → Map → Map renderer** to **Raster (classic)**.

### Dash link fails or drops: export the log

1. In the app: **Settings → Diagnostics → Export log**. Only in **Debug** builds (run from Xcode) and **TestFlight** builds; App Store builds hide it.
2. Share the text file to yourself.
3. Read it with the log guide in `CLAUDE.md` → *What to do when stuck* (`fix gap`, `render stall`, `rtp gap`, `Link dropped (reason)`).

Other quick checks:

- **Settings → Check permissions**: Local Network must be green, or no packet reaches the dash.
- *"Expected SSID … but on …"*: the phone is on a different Wi-Fi than the selected bike. Join the bike's `RE_…` network, or pick the right bike in **Settings → Bikes**.
- Still pointing at the fake_dash Mac: remove the `-BikeLink.bikeHost` launch argument (section 6.3).
