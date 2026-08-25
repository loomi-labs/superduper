<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/othneildrew/Best-README-Template">
    <img src="assets/superduper-nobg.png" alt="Logo" width="80" height="80">
  </a>

  <h3 align="center">SuperDuper App</h3>

  <p align="center">
    An alternative ebike app.
    <br />
    <a href="https://discord.gg/STvgARZYaw"><strong>Join the Discord</strong></a>
    <br />
    <br />
    <a href="https://testflight.apple.com/join/Tl0UibRY">iOS Download</a>
    ·
    <a href="https://play.google.com/store/apps/details?id=io.kbl.superduper">Android Download</a>
    ·
    <a href="https://github.com/blopker/superduper/issues">Bug Reports</a>
  </p>
</div>
<br/>

Features:

- No account or internet connection required
- Quickly switch between multiple bikes
- Lock settings, like Mode, to automatically switch when the bike is turned on and the app is running
- Custom modes: pick your own speed limit, with or without throttle, on any bike
- (Android only) The app keeps your locks and your speed limiting working while the phone is locked, on its own
- Open source

## Getting Started

- Open the app and select the "Select Bike" button. This will find any bikes around you that are on and save the details into the app.
- Select your bike in the list.
- Set the settings you want to use. These can be changed at any time.

Optionally, you can tap the "Edit" button to change the name of the bike.

**Make sure your bluetooth is on**

## Bike Functions

Control your bike's functions by tapping the buttons on the screen. Each card has a padlock icon with three states.
One tap moves to the next state:

- **Open** — the app holds nothing. The bike turns on with its own default.
- **Pinned for the ride start** (pin icon) — the app keeps the value you had when you tapped. When the bike is turned
  off and on again, the app writes that value back.
- **Locked** — the app holds the value all the time. If the bike reports a different value, the app writes yours back.

### Light

If your bike has them, this toggles your bike's lights on and off.

### Mode

Changes the legal category your bike will operate at. PAS is Pedal Assist System,
which means the motor will only run when you are pedaling.
Throttle means the motor will run when you press the throttle, regardless of if you are pedaling or not.

Every mode your bike can use is a button of its own, labeled with its speed limit — `20 mph`,
`25 km/h`, and so on — because that is what you actually need to know before you pick one. The
firmware's own name for the mode (`ECO`, `EPAC`, ...) shows in the tooltip, not on the button.
One tap selects it, there is no cycling through the modes you don't want. Which modes are
listed depends on the bike's region, plus any custom modes you added to that bike.

If your bike's firmware refuses to change one of Mode, Assist or Light, that card shows its
current value with no button to tap, instead of a picker that would do nothing.

#### US:

| Mode | Speed Limit         | Firmware Name | Class    | PAS | Throttle |
| ---- | ------------------- | ------------- | -------- | --- | -------- |
| 1    | 20 mph              | ECO           | 1        | Yes | No       |
| 2    | 20 mph + throttle   | TOUR          | 2        | Yes | Yes      |
| 3    | 28 mph              | SPORT         | 3        | Yes | No       |
| 4    | OFFROAD             | OFFROAD       | Off-Road | Yes | Yes      |


#### EU:

| Mode | Speed Limit | Firmware Name | Class    | PAS | Throttle |
| ---- | ----------- | -------------- | -------- | --- | -------- |
| 1    | 25 km/h     | EPAC           | EPAC     | Yes | No       |
| 2    | 35 km/h     | MODE 2         | 250W     | Yes | No       |
| 3    | 45 km/h     | MODE 3         | 850W     | Yes | No       |
| 4    | OFFROAD     | OFFROAD        | Off-Road | Yes | Yes      |

#### CH:

Swiss bikes have no limited mode of their own in the firmware, so the only firmware mode listed
is OFFROAD. Everything below that limit is a [custom mode](#custom-modes), and every CH bike
starts with one already set up:

| Speed Limit          | Kind              | PAS | Throttle |
| --------------------- | ----------------- | --- | -------- |
| 25 km/h (see below)   | Custom (pre-made) | Yes | Yes      |
| OFFROAD               | Firmware          | Yes | Yes      |

The pre-made "25 km/h" mode is an ordinary custom mode: you can rename it, change its limit and
its throttle setting, or add more modes next to it. A CH bike always keeps at least one custom
mode, so the last one can't be deleted without another one taking its place.

CH is the region newly added bikes start with. You can change the region at any time in the bike's
Edit sheet.

#### Custom Modes

A custom mode is yours, saved per bike, and available in every region. You add and edit them in
the bike's Edit sheet, under "Custom Modes". Each one has:

- a **name** (up to 12 characters, it's what the mode's button shows),
- a **speed limit**, 25 to 45 km/h, and
- a **throttle** switch. With throttle on, the limit can only go up to 32 km/h: the only faster
  profile in the firmware that has a throttle is the unlimited one, and a dropped Bluetooth
  connection must never leave your bike unlimited.

Some limits are exactly what one of the bike's firmware profiles already does, for example
32 km/h with throttle, or 25, 35 and 45 km/h without. Those modes are simply that profile: the
bike enforces the limit itself and keeps doing it whether or not the app is around.

Every other limit is the app switching between two firmware profiles at your limit, the same
way the old Swiss dynamic mode did. While the mode is selected, the app watches your speed
over Bluetooth. Below the limit the bike runs the closest faster profile with the throttle
setting you picked, so you get your throttle if you asked for one. Above the limit the app
switches to the fastest profile that caps at or under your limit. When you slow to about
2 km/h below the limit, it switches back, so the mode does not flip-flop at the limit.

The honest cost of that: if Bluetooth drops while you are riding *below* the limit, the bike
stays in that first profile, and that profile's own cap can be as high as 45 km/h, until the
app reconnects. It is never unlimited, but it is not your limit either. The mode editor spells
out the exact number for each mode while you set it up.

On Android, a switching custom mode keeps the app running in the background (and shows a
notification), so the switching keeps working while your phone is locked or in your pocket. New
CH bikes start in such a mode, so this also happens the first time you open a newly added bike,
without you selecting anything. It stops when you leave the mode, unless one of your locks still
needs it. On iOS there is no background service, so if the app is closed or the phone is locked
the switching stops and the bike stays in the profile that was written last. A mode that exactly
matches a firmware profile needs none of this.

### Assist

Changes the amount of assist your bike will provide while pedaling.
0 is no assist, 4 is full assist. This does not affect throttle power.
Each level is a button of its own, so one tap picks the level you want.

### Running in the background (Android only)

**Uses extra battery.** There is nothing to switch on. Whenever a lock is on, or a switching
custom mode is selected, the app keeps itself running and shows a notification, so your settings
are still applied after you close the app or your phone goes to sleep. It stops on its own when
you open the last lock and leave the switching mode. A line at the foot of the bike page says
what it is doing, and says so too if you refused the notification it needs.

### Auto-reconnect

In the bike's Edit sheet, on by default. The app connects to the bike whenever it is in range
and reapplies your settings. Turn it off and the app never connects on its own: that's how you
power-cycle the bike back to its own firmware defaults without the app immediately taking it
over again. The Connect button on the bike's page always works, whatever this setting says.

One exception: while a [custom mode](#custom-modes) that switches profiles is selected, the app
keeps reconnecting anyway, because the speed limiter can only come back after a dropout if it
reconnects. Pick OFFROAD, a firmware mode, or a custom mode that exactly matches a firmware
profile for the setting to take full effect.


## FAQ

### The app won't connect to my bike

Make sure your bike is on and your bluetooth is on. If you're on Android, make sure the app has location permissions. If you're on iOS, make sure the app has bluetooth permissions. Additionally, on some devices GPS needs to be enabled for scanning to work.

Make sure only one app is connected to the bike at a time. If you have the official app open, disconnect from the bike within the app, and close it. It can also help to uninstall the official app.

You can also try restarting the bike and your phone.

Finally, older bike firmware may not be supported. Make sure your bike firmware is up to date from the official app.

### Does a lock still work when the app is closed?

On Android, yes. The setting lock tells SuperDuper to ignore whatever the bike is set to and use
the setting you locked in the app. This is useful for when the bike starts up and its settings
reset, like lights and mode. A lock, or a switching custom mode, keeps the app running in the
background on its own, so the setting is still applied while your phone is in your pocket. It
takes extra battery, so it stops as soon as nothing needs it.

On iOS there is no background service, so a lock only works while the app is open.

### What's up with the bike names?

The bike names are randomly generated from your bike's unique ID, to make it easier to read and differentiate between multiple bikes. You can change the name in the bike's Edit page after you connect to the bike for the first time.

### What are the supported devices?

Right now the app requires Android 10+ and iOS 12+.

### What bikes are supported?

So far, all bike models have worked. Open a ticket if your model is having issues!

### Can this app make the bike go even faster?

Superduper can only add automation around what the official app already does. It cannot, for instance, program the controller. This is the job of the firmware, software that runs on the bike itself.

### How do I get the logs off my phone?

Superduper keeps a ride log on the device: a rotating text file at `logs/superduper.log` in the app's private documents directory. The budget is about 32 MB — enough for several full rides — and only once it is exceeded does the oldest file get deleted. Every line is timestamped, so individual rides are easy to tell apart. It records detailed Bluetooth traffic — connects, register reads, mode/light/assist writes, speed notifications — in normal store builds too, which is what makes it useful when something goes wrong on an actual ride. Superduper never uploads the log on its own. To send it along with a bug report, tap **SHARE LOGS** at the bottom of the bike select screen and pick an app to share the file(s) with.

### I'm having another issue or have a feature request

I'm sorry! Please start by making sure you have the newest app from the app store. After that, please submit the issue to https://github.com/blopker/superduper/issues. It helps to have a way I can reproduce the issue, with screenshots or video. Alternatively, you may have luck either clearing all the app's data or reinstalling it.

## Developers

### Releases

1. Update version, save. Don't commit.
1. Run `make release`. A release build needs `android/key.properties`. Without it the build stops, because the artifact would carry the debug certificate. For a local release build without keys, run `ORG_GRADLE_PROJECT_allowDebugSigning=true flutter build apk --release` — that artifact is for testing only, and no store accepts it.
1. Update release notes at provided URL.
1. Upload aab to https://play.google.com/console/u/0/developers/6048825475784314007/app/4973912181639360195/tracks/internal-testing
1. Upload ipa to the Transporter app
1. Release Android on Play store
1. Release iOS on https://appstoreconnect.apple.com/apps/1665290602/appstore/ios/version/inflight
