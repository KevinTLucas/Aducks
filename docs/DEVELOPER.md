# Aducks: developer notes

The user guide is [README.md](../README.md). This file covers how Aducks works and
how to extend it.

## How sign-in works

1. **Sign in** launches the configured Chromium browser with an isolated temp
   profile (`%TEMP%\Aducks-<guid>`) and a local remote-debugging port, opened at
   [Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer).
2. Once the page loads, Aducks clicks the Graph Explorer **Sign in** button
   (`SignInSelector` in `config/settings.json`; `""` disables it).
3. Over the Chrome DevTools Protocol, Aducks watches network requests and takes
   the `Authorization: Bearer <token>` header from the first request to
   `graph.microsoft.com`. That is the same token Graph Explorer shows in its
   "Access token" tab.
4. In the capture's `finally` block, the browser is killed and the temp
   profile deleted. Deletion is best-effort (`SilentlyContinue`, no wait for
   exit), so stray `%TEMP%\Aducks-*` folders are possible.
5. The JWT is decoded and held **in memory only**. `GET /v1.0/me` is then called.
   Only a 401 there blocks sign-in; any other failure still signs you in.
   `/organization` and `/me/photo` are fetched too, and their failures are
   ignored.
6. The session ends 30 s before `exp` (`ExpirySkewSec`), or on a 401 from any
   query, from Load more, or from the `/me` re-check that runs every 120 s
   (`RevalidateIntervalSec`). You only get an access token (no refresh token), so
   the only way to continue is to sign in again.

Graph Explorer's app is already consented, so there is no app registration. Some
scopes (e.g. AuditLog.Read.All) still need tenant admin consent.

**Known limitation:** managed devices can disable browser remote debugging by
policy (`RemoteDebuggingAllowed = 0`). Capture then fails after about 30 s
(`CdpEndpointTimeoutSec`) with "Could not reach the browser's remote-debugging
endpoint…". The fallbacks,
neither built yet, are a loopback PKCE flow or reading the browser's MSAL cache.

## Running

| Launcher | Use |
|---|---|
| `Aducks.bat` | Normal use. Starts PowerShell minimized + hidden (brief console flash). No VBScript, which Microsoft is phasing out |
| `Aducks-debug.bat` | Visible console (`-NoExit`, `$VerbosePreference='Continue'`). Shows startup errors |
| `powershell -NoProfile -ExecutionPolicy Bypass -STA -File src\Main.ps1 -Preview` | Preview mode with fake data, no sign-in |
| add `-NoActivate` | Opens without taking focus. Use it for automated UI tests so they can't catch the user's typing |

It needs Windows PowerShell 5.1 and .NET Framework/WPF, both built into Windows 10
and 11. `-STA` is required.

Sign-in capture and queries run in background runspaces (Graph.psm1 is
re-imported there). Cdp.psm1's `Write-Verbose` output is therefore **not**
shown in the debug console. For capture diagnostics, run
`Invoke-GraphTokenCapture -Verbose` on its own (see the Cdp.psm1 header).

Every request is a GET. Query and Load more requests also send
`ConsistencyLevel: eventual`. Any key in
`settings.json` overrides the matching default in `Config.ps1` (e.g.
`RevalidateIntervalSec`, `CdpEndpointTimeoutSec`).

## Project layout

```
Aducks.bat                Launcher (hidden)
Aducks-debug.bat          Launcher with console (shows startup errors)
config/
  settings.json           Browser, sign-in selector, login wait (defaults: Edge)
  queries.json            Query catalog (edited via the in-app Query catalog)
docs/
  DEVELOPER.md            This file
  DEPENDENCY-AUDIT.md     Third-party dependency review
src/
  Main.ps1                Entry point: UI wiring, query runner, JSON tree
  Config.ps1              Loads config/*.json
  ConfigEditor.ps1        Query catalog window (new / clone / chained steps)
  SettingsEditor.ps1      Settings window
  lib/Newtonsoft.Json.dll JSON parsing/formatting (MIT, net45)
  ui/*.xaml               MainWindow, ConfigEditor, SettingsEditor, Theme
  modules/
    Cdp.psm1              Browser launch + token capture (DevTools Protocol)
    Jwt.psm1              JWT decode
    Graph.psm1            Graph REST, URI builder, chained-query runner
    AuthState.psm1        In-memory token state + expiry
```

## queries.json format

A **Category** groups **Queries**. Each query has **Lookups** (the "how do you
want to find it" options) and **Props** (the return properties users can tick;
none are ticked by default).

```json
{
  "_readme": "...",
  "categories": [
    { "Category": "User",
      "Queries": [
        { "Label": "Direct group memberships",
          "Lookups": [ { "Label": "UPN", "Url": "users/{value}/memberOf" } ],
          "Props": [ "id", "displayName", "mail" ] } ] } ]
}
```

- `{value}` is replaced with the user's input. It is OData-escaped (`'` becomes
  `''`), then URL-encoded. Values extracted by chain steps get the same
  treatment. If there is no `{value}`, no value box is shown.
- A relative `Url` is added to the Graph v1.0 base. A full URL is used as the
  whole URL (no v1.0 prefix). `$select` is still appended, and spaces and `"`
  are still encoded. Full URLs must be `https://graph.microsoft.com/...`:
  `Invoke-GraphRequest` refuses every other host, so the token can't leak.
- If a query has only one lookup, the lookup step is hidden.
- `ValueLabel` / `ValueHint` (optional, per lookup) set the value box label
  (shown upper case; default "VALUE - <lookup label>") and placeholder.
- The ticked **Props** become `$select`. If none are ticked, Graph returns its
  default fields.

### Chained lookups

A lookup can use `Chain` instead of `Url`. It runs its steps in order. Each
step's `Extract` path (dotted, with `[n]` indexes) becomes the next step's
`{value}`. The last step's result is what gets shown, and `$select` applies only
to that step.

```json
{
  "Label": "Display name",
  "Chain": [
    { "Url": "groups?$filter=displayName eq '{value}'", "Extract": "value[0].id" },
    { "Url": "groups/{value}/members" }
  ]
}
```

If a step's `Extract` finds nothing, the query stops with "No match: step N
returned nothing at '…'. Check the value you entered."

The in-app editor validates chains: at least 2 steps, a URL on every step, and
an `Extract` on every step except the last. Saving from the editor rewrites
queries.json. It drops keys the editor doesn't know about, and empty
`ValueHint` / `ValueLabel` values.

## Security notes

- The token is the user's own, from their own sign-in.
- Only the `Authorization` header of `graph.microsoft.com` requests is read.
- Aducks never writes the token to disk. However, Graph Explorer's own sign-in
  cache sits in the temp browser profile until cleanup (best-effort, see
  above), and **Copy token** puts the token on the clipboard, where Windows
  clipboard history may keep it.
