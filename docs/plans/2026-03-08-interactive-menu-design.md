# Interactive Menu Design

**Goal:** Add a launcher menu so users can Connect, Test DNS, Configure, View Results, Clear Results, and get Help — all from one place.

**Approach:** Boxed styled menu shown when `start.sh`/`start.bat` is run with no arguments. CLI flags bypass the menu and run the existing flow directly.

---

## Menu Layout

```
╔══════════════════════════════════════╗
║       SlipStream Auto Connector      ║
╠══════════════════════════════════════╣
║                                      ║
║   [1]  Connect                       ║
║   [2]  Test DNS                      ║
║   [3]  Configure                     ║
║   [4]  View Results                  ║
║   [5]  Clear Results                 ║
║   [6]  Help                          ║
║   [7]  Exit                          ║
║                                      ║
╚══════════════════════════════════════╝

  Choose [1-7]:
```

- Box-drawing characters for borders, cyan/green colors matching existing log style
- Banner shown above the menu box
- User types a number to select
- After each action completes, returns to main menu (loop)

---

## Menu Options

### 1. Connect

- Check `results/dns-working.txt` for a previously ranked best DNS
- If found: connect directly using the #1 entry (best score)
- If not found: automatically run a full scan (tier 0 → 1 → 2), then connect with the best result
- Phase 2 runs as-is (connect, health check, auto-reconnect)
- On Ctrl+C or connection end: return to main menu instead of exiting

### 2. Test DNS

- Scans tier-by-tier automatically: tier 0 (custom) → tier 1 (previously working) → tier 2 (dns-list.txt)
- Shows persistent reminder: "Press Ctrl+C to stop and use best result so far"
- Displays ranked results table at the end (top working DNS with scores)
- Does NOT connect — just tests and saves results to dns-working.txt

### 3. Configure

- Sub-menu listing each config setting with its current value:
  ```
  [1] Domain: example.com
  [2] Workers: 5
  [3] Timeout: 3
  [4] Health Check Interval: 30
  [5] Max Reconnect Attempts: 0
  [6] Prioritize Known Good: true
  [7] Skip Previously Failed: true
  [8] Back to main menu
  ```
- User picks a number, types new value
- Saved to config.ini immediately
- Shows confirmation message
- Returns to configure sub-menu for more changes

### 4. View Results

- Show top 10 working DNS from dns-working.txt with scores
- Show count of failed DNS entries
- Show last session timestamp from session.log
- If no results exist, say so

### 5. Clear Results

- Prompt: "This will delete dns-working.txt and dns-failed.txt. Are you sure? (y/n)"
- On yes: delete both files, show confirmation
- On no: return to menu

### 6. Help

- Show existing help text: usage, CLI options, examples
- Explain menu options briefly

### 7. Exit

- Clean exit

---

## Entry Point Behavior

**No arguments:** Show menu
```
./start.sh          → menu
.\start.bat         → menu
```

**With arguments:** Bypass menu, run existing Connect flow directly
```
./start.sh -w 10           → existing flow (Phase 1 + Phase 2)
./start.sh --connect       → existing flow
./start.sh -u my-dns.txt   → existing flow
```

This preserves backward compatibility for power users and scripts.

---

## Architecture

- New file: `unix/lib/menu.sh` — menu rendering and option handlers (bash)
- New file: `windows/lib/Menu.ps1` — menu rendering and option handlers (PowerShell)
- Modified: `unix/slipstream-connect.sh` — check for args, show menu or run existing flow
- Modified: `windows/slipstream-connect.ps1` — same
- Modified: `unix/start.sh` / `windows/start.bat` — no changes needed (already pass args through)

Menu functions call into existing library functions (start_dns_testing, start_slipstream_connection, read_config, etc.) — no duplication.

---

## Config Editing

- Read current config.ini, parse values
- Write back to config.ini preserving comments and structure
- Only modify the specific key=value line that changed
- Use sed (bash) / string replacement (PowerShell) for in-place editing

---

## Cross-Platform Parity

Both bash and PowerShell versions must have identical menu options, layout, and behavior. The box-drawing characters and colors work in all modern terminals (Windows Terminal, CMD, PowerShell, Linux/macOS terminals).

---

## No New Dependencies

Everything uses shell built-ins + existing project functions. No external TUI libraries.
