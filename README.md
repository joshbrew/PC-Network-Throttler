# Network Throttler

A Windows desktop utility with live per-app upload and download rates, shared PC limits, and rules for individual apps.

<img width="2090" height="1316" alt="image" src="https://github.com/user-attachments/assets/cb16026b-1d84-4551-aa78-a877c2369b36" />

Made this to stop GPT from eating my upload bandwidth.

## Setup

Extract the Windows install ZIP or clone the repository on Windows 10 or 11. 

- Open **Run.cmd** to start setup on a fresh PC. 

- Open **Install.cmd** whenever you want the setup menu.

Setup offers 

**1. Install or update**<br/>
**2. Clean reinstall**<br/>
and **3. Uninstall** 

When the app is already installed. 

Updating keeps your saved limits. Clean reinstall removes the app and its saved rules, then installs it with the default settings. Setup asks you to confirm clean reinstall or uninstall.

When installing or updating, choose whether to create or keep a desktop shortcut, then approve the Windows administrator prompt. On x64 Windows, setup can also add PC-wide download and per-app limits if packet support is needed. Setup offers to open the app once it finishes. To choose a different initial upload speed, run `Install.cmd -UploadMbps 15` from a terminal.

Packet support downloads a pinned, signed [Windows Packet Filter](https://www.ntkernel.com/windows-packet-filter/download/) installer and verifies its signature and hash. This is free for personal use under the vendor's terms. The installer compiles this repository's packet worker using the Windows .NET Framework compiler, installs it as a Windows service, and stores files in `Program Files`.

The repository keeps the C# and XAML source in `src/` and the PowerShell installer and app scripts in `scripts/`.

## Open and use the app

Open **Run.cmd** or the **Network Throttler** desktop shortcut, then approve the Windows prompt. Each checkbox applies its direction immediately using the rate alongside it. Unchecking keeps the speed saved. Select **Save speeds** or **Save rule** to apply edited speeds without changing the checkboxes.

Search by app name, executable name, or path. Click any column header to sort, and click it again to reverse the order. The running list updates in the background and preserves the selected sort. Rules apply to instances of the selected executable and stay in the list when the app closes. Choose **Remove rule** to discard both saved speeds for that executable.

The **Upload (Mbps)** and **Download (Mbps)** columns show current traffic. **Upload limit** and **Download limit** show the saved rules. Live rates group active processes by executable and average over roughly three seconds. The monitor reads Windows TCP and UDP byte counts while the window is open. It works with the standard installer and keeps its samples in memory.

## Start with Windows and uninstall

The startup task restores the saved PC-wide upload setting. With packet support installed, the service restores enabled download and app limits. A service with all packet limits off leaves packet forwarding to Windows.

Choose **Uninstall** in setup, the app window, or **Settings → Apps → Installed apps → Network Throttler**. This removes the rule, startup task, service, desktop shortcut and installed files. It also removes the packet driver when this installer owns it.

## How network limits apply

PC-wide upload uses the Windows QoS scheduler. Packet support paces traffic on connected Windows adapters with a default gateway. The app limiter associates TCP and UDP connections with their executable using Windows' local connection tables. Encrypted tunnels, shared sockets and traffic from separate helper executables can affect per-app attribution. A PC-wide limit applies alongside matching app limits.

Download shaping controls delivery to the PC. Normal TCP senders adapt to the paced stream. Inbound packets reach the PC after crossing the internet link. Router-side shaping is needed for control at the gateway. [Microsoft QoS documentation](https://learn.microsoft.com/en-us/windows-server/networking/technologies/qos/qos-policy-manage)
