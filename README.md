# SlipStream Auto

Automatically finds a working DNS resolver from a large list, connects to the internet via `slipstream-client`, and keeps the connection alive with auto-reconnect.

Built for situations where internet access requires tunneling through specific DNS resolvers, and you have a list of thousands of candidates but no time to test them one by one.

## Project Structure

```
slipstream-auto/
├── windows/                # Windows scripts
│   ├── start.bat           # Double-click to run
│   ├── slipstream-connect.ps1
│   └── lib/
│       ├── Config.ps1
│       ├── Connect.ps1
│       ├── Logger.ps1
│       └── Test-Dns.ps1
├── unix/                   # Linux / macOS scripts
│   ├── start.sh            # Run this
│   ├── slipstream-connect.sh
│   └── lib/
│       ├── config.sh
│       ├── connect.sh
│       ├── logger.sh
│       └── test-dns.sh
├── config.ini              # Shared config (both platforms)
├── dns-custom.txt          # Your own DNS list (optional, highest priority)
├── dns-list.txt            # DNS list (~35k entries)
├── results/                # Generated at runtime
└── README.md
```

Place `slipstream-client.exe` (Windows) or `slipstream-client` (Linux) in the **root folder**.

## How It Works

1. Loads DNS entries using a **4-tier priority system** (see below)
2. Tests multiple DNS entries **in parallel** — spawns `slipstream-client` for each, checks for tunnel establishment within 3 seconds
3. Verifies **actual internet connectivity** through the SOCKS5 proxy (not just tunnel up)
4. Connects using the first confirmed working DNS
5. Monitors connection health and **auto-reconnects** if the connection drops
6. Saves results so future runs are faster (working DNS prioritized, failed DNS skipped)

### DNS Priority Tiers

DNS entries are tested in this order. The search stops as soon as a working DNS is found:

| Tier | File | Description |
|------|------|-------------|
| 0 | `dns-custom.txt` | Your own DNS entries (optional, highest priority) |
| 1 | `results/dns-working.txt` | DNS that worked in previous runs (auto-generated) |
| 2 | `dns-list.txt` | Combined list of ~35,000 resolvers |

Duplicates are removed across tiers, and previously failed DNS are skipped.

To add your own DNS entries, create a `dns-custom.txt` file in the root folder with one IP per line. You can also pass a custom path via CLI (see Command Line Options).

## Requirements

**Windows:**
- Windows 10/11 (PowerShell 5.1+ and curl.exe are included)
- `slipstream-client.exe`

**Linux / macOS:**
- Bash 4.0+
- `curl`
- `slipstream-client` binary (Linux/macOS build)

Both platforms need DNS list files (included in the release).

## Quick Start

### Windows

1. Download/clone this repo
2. Place `slipstream-client.exe` in the root folder
3. Edit `config.ini` — set your `Domain`
4. (Optional) Add your own DNS entries to `dns-custom.txt`
5. **Double-click `windows\start.bat`**
6. Wait for it to find a working DNS and connect
7. Set your browser/system proxy to **SOCKS5 `127.0.0.1:<port>`** (the port is shown in the output)

### Linux / macOS

```bash
git clone https://github.com/FZ1010/slipstream-auto.git
cd slipstream-auto
# Place your slipstream-client binary in the root
# Edit config.ini — set your Domain
chmod +x unix/start.sh
./unix/start.sh
```

## Configuration

Edit `config.ini` in the root folder (shared by both platforms):

| Setting | Default | Description |
|---------|---------|-------------|
| `Domain` | `example.com` | slipstream-client domain |
| `CongestionControl` | `bbr` | Congestion control algorithm |
| `KeepAliveInterval` | `2000` | Keep-alive in milliseconds |
| `Timeout` | `3` | Seconds to wait for tunnel establishment |
| `Workers` | `5` | Parallel DNS test workers |
| `ConnectivityUrl` | Google 204 check | URL for internet verification |
| `HealthCheckInterval` | `30` | Seconds between health checks |
| `MaxReconnectAttempts` | `0` | Max reconnects (0 = unlimited) |
| `PrioritizeKnownGood` | `true` | Try previously working DNS first |
| `SkipPreviouslyFailed` | `true` | Skip previously failed DNS |

## Command Line Options

### Windows (PowerShell)

```
.\windows\slipstream-connect.ps1 [options]

  -ConfigPath <path>    Path to config.ini
  -DnsListPath <path>   Path to dns-list.txt
  -UserDnsPath <path>   Path to your own DNS file (highest priority)
  -Workers <number>     Override parallel worker count
  -Help                 Show help
```

Or just double-click `windows\start.bat` (passes arguments through):

```
windows\start.bat -Workers 10
```

### Linux / macOS (Bash)

```
./unix/slipstream-connect.sh [options]

  -c, --config <path>     Path to config.ini
  -d, --dns-list <path>   Path to dns-list.txt
  -u, --user-dns <path>   Path to your own DNS file (highest priority)
  -w, --workers <number>  Override parallel worker count
  -h, --help              Show help
```

Or just use `unix/start.sh`:

```bash
./unix/start.sh -w 10
```

## Output Files

After running, check the `results/` folder in the project root:

- **`dns-working.txt`** — DNS entries that were confirmed working (with timestamps)
- **`dns-failed.txt`** — DNS entries that failed (skipped on future runs)
- **`session.log`** — Full log of the session

To re-test previously failed DNS entries, delete `results/dns-failed.txt`.

## Troubleshooting

- **"No working DNS found"** — Your DNS list may be outdated. Get a fresh list, or delete `results/dns-failed.txt` to retry failed ones.
- **"slipstream-client not found"** — Place the binary in the **root folder** (not inside windows/ or unix/).
- **"curl not found"** — Windows: need Windows 10+. Linux: `sudo apt install curl` (or equivalent).
- **Connection drops frequently** — Increase `HealthCheckInterval` in config.ini or try more workers to find better DNS entries.
- **Too slow** — Increase `Workers` in config.ini (e.g., 10 or 20). More workers = more parallel tests.
- **Script stuck / can't Ctrl+C** — The script registers cleanup handlers. If it's truly stuck, close the terminal window. Kill orphaned processes: `taskkill /F /IM slipstream-client.exe` (Windows) or `pkill slipstream-client` (Linux).

## Contributing

1. Fork the repo
2. Create a branch (`git checkout -b feature/my-thing`)
3. Commit your changes
4. Push and open a Pull Request

## License

[CC BY-NC 4.0](LICENSE) — Free to use, share, and modify. **Commercial use is not permitted.**
