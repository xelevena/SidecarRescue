_This project was developed with assistance from OpenAI Codex._

# SidecarRescue

SidecarRescue gives a MacBook with a broken built-in screen a quick way to
reconnect to the owner's iPad over USB and use it as a Sidecar display.

The initial setup may require access to an external monitor or TV. After setup,
you can take the MacBook outside with only an iPad and a data-capable USB cable:
blind-type the Mac login password if FileVault is enabled, press a keyboard
shortcut, and wait for the iPad to become the Mac display.

Sidecar supports iPads only. An iPhone cannot be used as a Sidecar display.

SidecarRescue installs a macOS Quick Action named `Connect iPad Display`.
Assign a global keyboard shortcut to that action, press the shortcut after
logging in, and the tool retries the wired Sidecar connection for up to three
minutes. It exits as soon as the connection succeeds or the timeout expires.
There is no permanent background agent.

## Requirements

- A Mac and iPad that support Sidecar
- macOS 13 or later
- Xcode command-line tooling for local builds
- An unlocked iPad connected with a data-capable USB cable
- The Mac and iPad signed in to the same Apple Account with two-factor
  authentication enabled
- The iPad configured to trust the Mac for USB connections

## Initial setup

You may want to connect the MacBook to an external monitor or TV while
performing the initial setup.

1. Unlock the iPad, connect it to the MacBook with a USB cable, and accept the
   trust prompt if macOS or iPadOS shows one.
2. Start Sidecar manually once and choose the option to mirror the built-in
   display. macOS should remember the display mode for later sessions.
3. Run the installer with the exact iPad name. The retry timeout defaults to
   `180` seconds:

```sh
./scripts/install.sh "My iPad"
```

   To configure a different timeout, pass it as the second argument:

```sh
./scripts/install.sh "My iPad" 300
```

4. Open:

```text
System Settings > Keyboard > Keyboard Shortcuts > Services > General
```

5. Assign a shortcut to `Connect iPad Display`.
6. Test the shortcut before relying on the setup away from home.

Running `install.sh` again replaces the previously configured iPad name,
timeout, installed CLI, and Quick Action. The keyboard shortcut remains
associated with the same `Connect iPad Display` service name.

## Use away from home

After restarting the MacBook with FileVault enabled:

1. Wait for the FileVault unlock screen to load.
2. Blind-type the Mac login password and press Return.
3. Wait for macOS to finish logging in.
4. Unlock the iPad and connect it to the MacBook with a USB cable.
5. Press the assigned shortcut.
6. Wait for the Sidecar display to appear.

If the MacBook is already logged in:

1. Unlock the iPad.
2. Connect the USB cable.
3. Press the assigned shortcut.
4. Wait for the Sidecar display to appear.

The retry process exits after a successful connection. If Sidecar remains
unavailable, it exits after three minutes.

## CLI

```sh
sidecar-rescue list
sidecar-rescue connect --device "My iPad" --wired
sidecar-rescue disconnect --device "My iPad"
sidecar-rescue rescue --device "My iPad" --timeout 180 --interval 3
```

## Uninstall

```sh
./scripts/uninstall.sh
```

## Limitations

SidecarRescue cannot show the FileVault unlock screen. If FileVault is enabled,
enter the Mac login password before using the shortcut.

This project calls an undocumented Apple framework. A future macOS update may
break it without warning. It is not affiliated with or endorsed by Apple.

## Acknowledgements

SidecarRescue is a derivative work based on
[Ocasio-J/SidecarLauncher](https://github.com/Ocasio-J/SidecarLauncher), an
MIT-licensed project by Jovany Ocasio. It adapts the original project's
private `SidecarCore.framework` bridge and extends it with a native rescue
retry mode, configurable timeout, installer, uninstaller, and macOS Quick
Action workflow. See [LICENSE](LICENSE) for the preserved copyright notice.
