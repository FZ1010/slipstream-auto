# SlipStream Auto

Automatically finds a working DNS resolver from a large list, connects to the internet via [slipstream-client](https://github.com/nicholasgasior/slipstream), and keeps the connection alive with auto-reconnect.

Built for situations where internet access requires tunneling through specific DNS resolvers, and you have a list of thousands of candidates but no time to test them one by one.

## How It Works

1. Loads your DNS list and shuffles it (previously working DNS are tried first)
2. Tests multiple DNS entries **in parallel** — spawns `slipstream-client.exe` for each, checks for tunnel establishment within 3 seconds
3. Verifies **actual internet connectivity** through the SOCKS5 proxy (not just tunnel up)
4. Connects using the first confirmed working DNS
5. Monitors connection health and **auto-reconnects** if the connection drops
6. Saves results so future runs are faster (working DNS prioritized, failed DNS skipped)

## Requirements

- **Windows 10/11** (PowerShell 5.1+ and curl.exe are included)
- **slipstream-client.exe** — place it in the same folder as the scripts
- **dns-list.txt** — one DNS IP per line

## Quick Start

1. Download/clone this repo
2. Place `slipstream-client.exe` in the root folder
3. Place your `dns-list.txt` in the root folder (or use the included one)
4. **Double-click `start.bat`**
5. Wait for it to find a working DNS and connect
6. Set your browser/system proxy to **SOCKS5 `127.0.0.1:<port>`** (the port is shown in the output)

## Configuration

Edit `config.ini` to customize behavior:

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
| `ShuffleDns` | `true` | Randomize DNS order each run |
| `PrioritizeKnownGood` | `true` | Try previously working DNS first |
| `SkipPreviouslyFailed` | `true` | Skip previously failed DNS |

## Command Line Options

```
.\slipstream-connect.ps1 [options]

Options:
  -ConfigPath <path>    Path to config.ini (default: .\config.ini)
  -DnsListPath <path>   Path to dns-list.txt (default: .\dns-list.txt)
  -Workers <number>     Override parallel worker count
  -Help                 Show help
```

Or just use `start.bat` which passes arguments through:

```
start.bat -Workers 10
```

## Output Files

After running, check the `results/` folder:

- **`working-dns.txt`** — DNS entries that were confirmed working (with timestamps)
- **`failed-dns.txt`** — DNS entries that failed (skipped on future runs)
- **`session.log`** — Full log of the session

To re-test previously failed DNS entries, delete `results/failed-dns.txt`.

## Troubleshooting

- **"No working DNS found"** — Your DNS list may be outdated. Get a fresh list, or delete `results/failed-dns.txt` to retry failed ones.
- **"slipstream-client.exe not found"** — Place the executable in the same folder as the scripts.
- **"curl.exe not found"** — You need Windows 10 or newer. For older systems, install curl manually.
- **Connection drops frequently** — Increase `HealthCheckInterval` in config.ini or try more workers to find better DNS entries.
- **Too slow** — Increase `Workers` in config.ini (e.g., 10 or 20). More workers = more parallel tests.

## Contributing

1. Fork the repo
2. Create a branch (`git checkout -b feature/my-thing`)
3. Commit your changes
4. Push and open a Pull Request

## License

[MIT](LICENSE)
