<p align="center">
  <img height="182" src="/assets/app-icon.png">
</p>

<p align="center">
  <img src="/assets/title.svg" alt="Let your agents run with your MacBook lid closed">
</p>

---

A macOS menu bar app that prevents your MacBook from falling asleep when the lid is closed, while letting the display turn off like normal to preserve battery and reduce heat.

Motivated by the need to let coding agents stay running while you carry your MacBook around.

<p>
  <img width="560" height="218" alt="590059860-a03f5bb4-d979-4af5-a895-949414f0efb8" src="https://github.com/user-attachments/assets/e3f5dc98-7fab-4e14-9bcb-6ff621a51d05" />
</p>

## Installation & Usage

Install through the `.dmg` in Releases.

Requires App Background Activity permission (`System Settings -> General -> Login Items & Extensions`). Should pop up automatically on first run.

Left click to open the status window, where you can see why Modafinil is active, inactive, or waiting, and activate/deactivate it. Right click for menu, where you can quit the app and also uninstall it.

Opening Modafinil from Launchpad or Finder shows the same controls in a regular app window, even when the menu bar icon is hidden because the menu bar is full. Closing that window returns Modafinil to its lightweight menu bar mode.

The menu also includes "Sleep When T3 Threads Finish (Lid Closed)", described below, and an "Only While Codex Is Running" option. When enabled, Modafinil keeps sleep prevention requested but only applies it while a Codex app or `codex` command is running.

## Sleep timer and confirmed results

Use **Sleep Timer** to choose 1–1440 minutes, update, or cancel. The privileged
helper stores the timer, so UI suspension and helper restarts do not lose it.
Quitting Modafinil cancels scheduled and pending sleep; reboot discards a timer.
Missed timers never put a just-awakened Mac back to sleep.

The helper requests sleep through public `IOPMSleepSystem`, records a durable
receipt, and checks kernel sleep/wake timestamps. Acceptance is not confirmation.
At most three requests run over 32 seconds; any observed sleep ends retries,
even if the Mac wakes immediately afterward. Native errors and missing sleep
transitions are reported in both apps. Continuous time bounds the timer and
verification window despite wall-clock changes. The journal is root-written
at `/Library/Application Support/Modafinil/sleep-journal.json`; it contains only
timer/result metadata, with no pairing keys, credentials, or screen contents.

The iPhone clears expired countdowns, refreshes on foreground entry and performs
one delayed result check. It labels an unreachable Mac as unverified. The Mac
continues to permit network wake and macOS maintenance; this is not a guarantee
of uninterrupted deep sleep. Companion 1.4 uses protocol v3; v1/v2 clients remain
compatible but cannot display sleep receipts.

Validation on 2026-09-29 included 40 passing Swift tests, a signed release build,
Mac timer save/cancel checks, and an approved live one-minute timer. macOS logged
software sleep from the helper at 21:14:51 CEST; the durable receipt confirmed
kernel sleep at 21:14:53 after one native request. Connecting USB-C caused a wake
at 21:16:13. macOS returned to sleep and fully woke at 21:17. Keep-awake was
restored and both test timers were cleared. Because power was connected during
sleep, this validates the sleep path and recovery but is not an isolated proof
of the scheduled wake source.

## Quit apps that keep the Mac awake before sleep (Mac 0.9.0)

Optional, in **Settings → Before sleeping** or the right-click menu. When Modafinil puts
the Mac to sleep (sleep timer, iPhone **Sleep Mac**, or T3 Code finishing), it first asks
apps that keep the Mac awake to quit, as with ⌘Q, so they can still ask to save. For a
sleep timer this happens 1 minute before it fires; for an immediate sleep, the helper's
retries over about 30 seconds give the apps time to close.

- An app counts when it, one of its helper processes, or a system service on its behalf
  (for example `coreaudiod` playing a browser tab's audio) holds a power assertion that
  prevents system sleep, idle sleep or display sleep. Background macOS work does not count.
- Never quit: T3 Code, Codex, ChatGPT, Claude, terminals, Xcode, VS Code, Cursor, the Finder
  and Modafinil, plus any app you add under **Never Quit Another App…**.
- Settings shows which apps would be quit right now. Each quit request is recorded in
  Sleep History. An app showing a save dialog stays open; the sleep result then names it.

## Sleep when T3 Code threads finish (Mac 0.7.0, switch everywhere in 0.7.1)

It is an on/off switch, off by default: in the menu bar popover, on the Overview page, in
Settings and in the right-click menu (**Sleep When T3 Threads Finish (Lid Closed)**).
While keep-awake is on, the lid is closed and no external display is connected, Modafinil
checks [T3 Code](https://github.com/pingdotgg/t3code) every 15 seconds. When no thread has
been working or waiting for 1 minute, it turns keep-awake off and puts the Mac to sleep,
the same way an iPhone sleep request does (remote wake stays armed). Opening the lid turns
keep-awake back on, so the next closed-lid agent session keeps running.

- A thread counts as active while its latest run is `preparing`, `queued`, `starting`,
  `running` or `waiting` (waiting for an answer or approval), the statuses T3 itself
  treats as active. Delegated subagent threads count too.
- Since Mac 0.9.1 a thread also counts while it waits on background work after its turn
  has ended, as T3 shows it: a background command, monitor or subagent the agent started
  (for example a long build it will check on), or a tool call still running. These threads
  are labelled **Background**. Pull request watches do not count: they wait on other
  people and can last for days.
- The minute of grace covers a subagent finishing before its parent resumes and a queued
  message starting the next turn.
- Since Mac 0.9.2 a **Wake & Keep Awake** from the iPhone, or a wake alarm, with the lid
  closed and this rule on, keeps the Mac awake even though T3 has already finished: the rule waits until a T3 thread starts
  working again and sleeps a minute after that run ends. Before, a closed-lid Mac woken
  from the iPhone fell back to sleep about a minute later. The next sleep request,
  opening the lid or changing the setting ends the wait. The iPhone card shows "sleeps after the next T3 run".
- If T3 Code is not running, nothing counts as working. If its state cannot be read
  (for example after a T3 update changes its database), Modafinil does not sleep and
  shows the reason.
- State is read from `~/.t3/userdata/statev2.sqlite`, read-only, with two small queries
  (a few milliseconds), only while the lid is closed. Nothing is written to T3.
- Scheduled T3 tasks cannot run while the Mac sleeps.
- Mac 0.8.0 / Companion 1.7 (protocol v6): the iPhone shows the setting with the live T3
  status or countdown and can turn it on or off. Older phones and Macs keep working; an
  older Mac answers with v5 or v4 and the phone asks for a Mac update for this setting.

## Redesigned Mac window (Mac 0.6.0)

The Modafinil window now uses a sidebar with five pages instead of one long column:

- **Overview**: status with the on/off button, timer, alarm, iPhone and last-sleep tiles, and other apps affecting sleep.
- **Timers**: sleep timer presets or custom minutes with a live countdown, next to the wake alarm.
- **Sleep History**: totals, a timeline chart, wake causes and an event table, for 24 hours, 7 days or a single day.
- **iPhone**: access status, Tailscale and relay addresses, recent iPhone actions, pairing.
- **Settings**: open at login, Codex mode, helper status, quit and uninstall.

The menu bar popover is a compact card with a keep-awake switch, sleep timer presets,
the wake alarm, iPhone status and a 24-hour strip. The interface is SwiftUI (macOS 13+).
It reads data only while visible, so it adds no background work. Behaviour, the helper
and the iPhone protocol are unchanged; no phone or relay update is needed.

## Sleep history, sleep blockers and reliability (Mac 0.5.0 / Companion 1.6)

**Sleep History…** (menu or status window) shows when the Mac was awake, in a
background (display-off) wake, or asleep, and why: idle, lid, Modafinil timer or
iPhone request, macOS maintenance, network activity, alarms. Modafinil's own
actions (keep-awake on/off and their source, timers, wake alarms, sleep results)
appear alongside. Recording is event-driven: the app reads a few kernel and
IOPMrootDomain values when macOS reports a wake, writes one small line to
`~/Library/Application Support/Modafinil/power-history.jsonl` (60-day retention),
and does no work while the Mac sleeps. Time between a recorded sleep and the next
wake is shown as asleep; time when Modafinil was not running is shown as no data.
It never parses `pmset -g log`, which can take a minute of CPU.

The status window lists **other apps affecting sleep** (power assertions such as
Chrome's video wake lock), read on demand and only refreshed while visible. A
failed sleep receipt now names the apps holding sleep assertions at that time.

Reliability changes:

- Modafinil opens at login (menu-bar only) so phone control survives restarts;
  toggle with **Open at Login**.
- The companion listener restarts itself after failures and after every wake.
- Every wake, including lid-closed network wakes, is observed through IOKit.
  macOS maintenance and background-task wakes no longer start the 90-second
  recovery keep-awake; network, lid, input and alarm wakes still do.
- The helper wakes once at the timer deadline instead of every second, and the
  app reacts to a helper notification instead of re-reading the journal every
  2 seconds. Codex detection no longer spawns `pgrep`.
- Sleep receipts keep the first wake after sleep instead of the latest one.

Protocol v5 adds the `history` command and signed blocker/history fields. Mac 0.5.0
still serves v1–v4 phones unchanged; the iPad relay is unchanged.

## Companion wake recovery (Mac 0.4.1 / Companion 1.5)

Protocol v4 signs the Mac's current private Wi-Fi and hardware wake addresses.
The phone refreshes its existing Keychain pairing from verified responses; it
preserves both secrets and all endpoints. The Mac prefers live addresses over
stale saved targets, retaining configured extra interfaces up to four total.
Install Mac 0.4.1 before Companion 1.5. Existing v1/v2/v3 phones and the iPad's
v1 relay retain their original protocol and response signatures.

The phone allows 60 seconds for network recovery and sends at most four signed
relay wake requests during that foreground attempt. Sleep timers now arm remote
recovery, and maintenance wakes retain the authorization until Keep Awake or an
explicit local change, cancellation or quit. Each wake still receives only the
existing 90-second provisional keep-awake lease, which can temporarily extend
background awake time. There is no new idle polling or permanent keep-awake.

Mac 0.4.1 also ignores already-fired records retained by macOS when replacing
or cancelling future wake alarms. Attempting to cancel such an expired record
returns IOKit Not Found and previously rolled back a valid replacement alarm.
Active Modafinil alarms and other apps' events remain protected.

Validation on 2026-10-07: 46 Mac Swift tests passed, the signed build was installed,
and a native one-minute timer produced kernel-confirmed sleep at 12:21:26 and a
later wake at 12:21:55 with recovery authorization retained. Provisional keep-awake
expired as intended. The wake was not isolated magic-packet proof. The paired
Companion build passes 29 tests, including late reconnect and signed address
updates. Installing the new Signulous IPA and a physical cellular/closed-lid AC
cycle remain user acceptance. Investigation and artifact recovery are recorded
in the companion repository's `docs/wake-recovery-2026-10-07.md`.

## Wake timer

Use **Wake Timer** in the Mac window or menu bar popover to pick a one-time
date and time, then click **Schedule Wake**. **Update Wake** replaces that alarm;
**Cancel Wake** removes it. Modafinil Companion 1.3 on iPhone controls the same
alarm with **Wake At…** and **Cancel Wake Timer**. Refresh the phone to see
changes made on the Mac.

The privileged helper uses `IOPMSchedulePowerEvent` to register a native wake
event, between one minute and 30 days ahead, owned by
`com.narcotic.modafinil.scheduled-wake`. Updates and cancellation preserve
other apps' power events. The alarm survives sleep and app restarts and needs
no iPhone or iPad connection once saved. Keep the Mac on AC and Modafinil open
to enable keep-awake after the alarm. The timer wakes from sleep; it does not
schedule shutdown/power-on, unlock the Mac, or launch a task itself.

Quitting the app leaves the wake alarm in macOS. Cancel it explicitly before
quitting if you do not want it. The app restores the pending alarm on launch;
alarms missed by more than five minutes do not unexpectedly enable keep-awake
when the app is reopened later. The sleep timer remains separate.

Companion protocol v2 authenticates the scheduled wake timestamp. The Mac still
serves v1 clients using their original response format; the existing jailbroken
wake relay and pairing secrets are unchanged.

## iPhone companion access

Open Modafinil from Launchpad and choose **Companion Setup…** to pair the iPhone companion app. Modafinil discovers the Mac's Tailscale IPv4 address and current Wi-Fi MAC address, lets you enter the XR wake relay address and up to four comma-separated wake MAC addresses, and creates a private pairing QR code.

The Mac listener is event-driven and listens on TCP port `48765`. It accepts only loopback and Tailscale source addresses. Every request and response is authenticated with a locally generated 256-bit secret; requests also require a current timestamp and a unique UUID to prevent replay. The root helper is never exposed to the network.

A companion sleep request first arms a one-time wake lease, disables Modafinil, and receives an acknowledgement from the signed local helper. After a short delay for the response, the helper requests sleep and records whether the kernel confirms it. When macOS posts its wake notification, Modafinil enables a 90-second provisional wake lease while the iPhone reconnects and confirms **Keep Awake**.

The pairing secret is stored only in the current macOS user's preferences. Generating a new secret invalidates all previous pairings.

For a local signed build, `build/build.sh` keeps the release identity as its default but accepts an override:

```sh
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build/build.sh
```

The helper derives its own signing team at runtime and accepts only the Modafinil app identifier signed by that same team.

Tested thus far only on Apple Silicon with macOS 13+.
