# MiniDrone / Mambo BLE control

MiniDrone mode adds an independent CoreBluetooth connection and flight workspace, using the existing keyboard/gamepad input configuration. The mode button opens a soft violet workspace with discovery, connection status, battery, flight state, flight commands and accessory controls. Existing Bebop/Sumo UDP clients and product routing are retained.

Bluetooth access is requested when **Search nearby** is first pressed. Choose the drone, connect, and use **Input settings** to enable inputs and adjust inputs. **Edit mappings** opens the keyboard/gamepad assignments directly. Flat trim and takeoff require a reported landed state. Landing and emergency remain available whenever the BLE connection is ready. After emergency, reconnect before resuming commands.

## Implementation

- Validates all eight requested GATT characteristics and their properties, then waits for all four notification subscriptions before enabling commands.
- Uses `[type, sequence, ARCommand payload]` BLE frames, independent sequence counters, reliable FIFO delivery on FA0B, acknowledgements on FB1B, and 150 ms retries (five retries after the initial transmission).
- Emergency uses FA0C/FB1C, takes priority, cancels queued normal commands and retries until acknowledged or disconnected.
- Reliable FB0E data is acknowledged through FA1E, including duplicate deliveries. FB0F carries unacknowledged telemetry. Duplicate/out-of-order events are filtered with sequence wrap handling.
- Requests common settings and states at connection. Sends current PCMD at 20 Hz, with neutral input when controls are disabled. Congestion never queues obsolete stick positions. Connection failures clear commands, telemetry, accessory IDs and input before reconnecting.
- Grabber/cannon IDs come exclusively from MiniDrone UsbAccessoryState events. Inventory handles first/last, empty and removed entries. Missing, unknown or busy accessories cannot issue actions. Accessory commands use class 16 on reliable FA0B.
- No MiniDrone firmware, USB debug, telnet or RNDIS implementation is involved. MiniDrone mode removes device tools and video actions from its menu surface.

Protocol references: [Parrot ARSDK network protocol](https://developer.parrot.com/docs/bebop/ARSDK_Protocols.pdf) and [Parrot legacy MiniDrone command definitions](https://github.com/Parrot-Developers/arsdk-xml/blob/legacy-branch/xml/minidrone.xml).

## Files changed for this feature

All source paths below are relative to `Sources/ParrotLab/`.

| File | Change |
| --- | --- |
| `MiniDroneProtocol.swift` (new) | BLE channel IDs, packet encoding, telemetry/accessory reducer, subscription barrier and deterministic retry scheduler. |
| `MiniDroneBLEClient.swift` (new) | CoreBluetooth discovery, connection, GATT validation, subscriptions, writes, telemetry and disconnect cleanup. |
| `MiniDroneViewController.swift` (new) | Violet workspace, flight/accessory controls and device selection. |
| `MiniDroneSelfTest.swift` (new) | Offline packet, queue, retry, ACK, sequence, telemetry, accessory, adapter lifecycle and mapping tests. |
| `MainViewController.swift` | MiniDrone mode button, workspace switching and shared input routing. |
| `FlightControl.swift` | Remappable MiniDrone flat trim, grabber open/close and cannon fire actions. |
| `LabVisualStyle.swift` | Soft violet theme. |
| `AppDelegate.swift` | Mode-aware settings, mappings and menus. |
| `SelfTest.swift`, `main.swift` | Integrated tests and dedicated MiniDrone test/preview entry points. |
| `PreviewRenderer.swift` | Offline MiniDrone workspace preview. |
| `../../Resources/Info.plist` | Bluetooth permission explanation. |
| `../../MINIDRONE.md` (new) | Integration notes and hardware checklist. |

## Verification

- Native macOS release compilation passed without compiler warnings.
- Dedicated `--self-test-minidrone` passed without creating a Bluetooth central manager.
- Full bundled `--self-test` passed. An earlier cold run failed the existing temporal-video renderer test; both the previously installed app and the new build subsequently passed.
- MiniDrone and existing Air layouts were rendered and inspected at the 1180 × 720 minimum window size.
- The local app was reinstalled at `~/Applications/Parrot Lab.app`, signature-verified and reopened. The installed MiniDrone self-tests passed. Distributable archives were unchanged.

Run the focused offline tests with:

```sh
"$HOME/Applications/Parrot Lab.app/Contents/MacOS/ParrotLab" --self-test-minidrone
```

## Live hardware checklist — still required

- [ ] Grant Bluetooth permission, discover the intended Mambo and connect. Check battery and flight-state updates. Repeat after denying/re-enabling permission and switching Bluetooth off/on.
- [ ] On a level surface, flat trim; then verify takeoff, hover and landing, including the displayed state transitions.
- [ ] Enable keyboard/gamepad controls. Verify roll, pitch, yaw and climb/descent directions, small inputs, full travel and neutral on release, focus loss or disabling controls.
- [ ] Exercise emergency cut-out in a safe bench setup. Confirm motors stop, queued actions do not resume and reconnect is required before more commands.
- [ ] Test grabber open/close, busy/ready transitions and remapping. With the cannon unloaded, test fire and remapping. Confirm IDs are learned automatically, including after changing accessories and reconnecting.
- [ ] While landed, disconnect/reconnect and interrupt the Bluetooth link. Confirm stale input and accessory IDs clear, no queued action replays and state updates resume after reconnection.
- [ ] Return to Air/Ground mode and verify existing Bebop/Sumo connections, input mappings and menus behave as before.

No live Mambo flight or accessory behavior has been validated during this implementation.

## Settings interaction fix

MiniDrone menu validation now permits input-setting and mapping changes. Choice menus no longer inherit the device-tool restrictions. Settings hides the unrelated Wi-Fi and video sections in MiniDrone mode; the workspace provides direct access to mappings. Device/accessory menus retain their items during unchanged telemetry updates so open menus remain selectable.

`--self-test-settings` exercises all input modes, keyboard/button/axis remapping, persistence, default restoration and menu stability. The full offline suite passed, and input and gamepad mapping choices were verified in the installed app. Existing user bindings were preserved.
