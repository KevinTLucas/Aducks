# Aducks — Dependency & Implementation Audit

Scope: identify custom code that duplicates functionality available from a mature,
maintained, free OSS .NET/WPF library, and decide whether replacing it is a net win.
Stack: Windows PowerShell 5.1 + WPF (.NET Framework 4.x), portable (no installer) —
so any dependency must be a single self-contained DLL loadable via `Add-Type`.

## Summary

The codebase is small and mostly glue over built-in .NET/WPF. The one true commodity
concern — JSON parsing/formatting — has been moved to **Newtonsoft.Json** this pass.
Everything else is either a built-in framework feature or small, stable custom code
where a library would add more weight (multiple DLLs, modern-.NET targeting) than value
on a PS 5.1 portable app.

| Area | Current | Verdict |
|------|---------|---------|
| JSON parse / pretty-print | **Newtonsoft.Json** (adopted) | ✅ Replaced custom code |
| JSON tree view | WPF `TreeView` + Newtonsoft `JToken` typing (~60 lines glue) | Keep (built-in control; no lightweight OSS drop-in) |
| Syntax-highlighted code editor | none (tree + copy) | Not needed; AvalonEdit if ever required |
| HTTP / Graph calls | `Invoke-RestMethod` / `Invoke-WebRequest` | Keep (built-in) |
| Chrome DevTools capture | custom CDP over `ClientWebSocket` (Cdp.psm1, 251) | Keep (PuppeteerSharp too heavy / wrong target) |
| JWT decode | custom base64url + parse (Jwt.psm1, 60) | Keep (decode-only; lib = many DLLs) |
| Config (JSON settings) | custom load/merge (Config.ps1, 93) | Keep (Newtonsoft-backed save) |
| MVVM | none (named elements + `$ui`) | Keep (app too small to justify a framework) |
| Logging | `-Verbose` + debug console | Keep |
| Dialogs / notifications | `MessageBox` + inline status | Keep (built-in) |
| Search / highlight | tree search (~20 lines) | Keep |
| Async | background runspace + `DispatcherTimer` | Keep (no async/await in PS 5.1) |
| Window chrome / dark title bar | P/Invoke DWM (~25 lines) | Keep (no library needed) |

## Details

### 1. JSON parse / format / pretty-print — REPLACED ✅
- **Was:** a hand-written re-indenter (`Format-Json`, ~50 lines) working around PS 5.1
  `ConvertTo-Json` quirks (double-space after `:`, `<`/`&`/`'` escaping),
  plus hand-rolled type detection for the tree (`Test-JsonObject`/`Test-JsonArray`/
  `Format-LeafValue`). The type detection mis-cast a value and crashed
  (`Cannot convert "#" to Brush`).
- **Now:** **Newtonsoft.Json 13.0.3** (net45, MIT, ~695 KB single DLL, the de-facto
  .NET JSON standard, actively maintained). `JToken.Parse(...).ToString(Indented)` for
  pretty output (Copy + config file writes); the tree is built by walking
  `JObject`/`JArray`/`JValue` with `JValue.Type` picking the colour.
- **Benefit:** removed ~90 lines of fragile parsing/formatting; fixed the crash; correct,
  hardened escaping and typing. Clear win for a commodity concern.

### 2. JSON tree view — KEEP (built-in + Newtonsoft)
- ~60 lines of glue turn a parsed `JToken` into WPF `TreeViewItem`s. The control itself
  is the framework `TreeView`; typing is Newtonsoft.
- No lightweight, PS-5.1-loadable OSS "WPF JSON tree" control exists that wouldn't add
  its own dependency chain. The glue is small, clear, and now robust. **Retain.**

### 3. Syntax-highlighted / code editor — NOT NEEDED
- Results are shown as a tree; the exact JSON is available via Copy. There is no
  in-app editable code view, so a code-editor library isn't warranted.
- If a raw, highlighted, editable JSON view is ever wanted, **AvalonEdit**
  (ICSharpCode.AvalonEdit, MIT, mature) is the right choice — but adding it now would be
  a dependency with no current use.

### 4. HTTP / Graph — KEEP
- `Invoke-RestMethod`/`Invoke-WebRequest` are built in, handle auth headers, JSON, and
  errors well (see Graph.psm1). RestSharp/Flurl/raw `HttpClient` add nothing here.

### 5. Chrome DevTools capture (Cdp.psm1) — KEEP
- Custom CDP over `System.Net.WebSockets.ClientWebSocket` to read the bearer token.
- OSS options (PuppeteerSharp, MasterDevs.ChromeDevTools) target modern .NET and pull
  large dependency trees / a browser download — inappropriate for a portable PS 5.1 tool.
  The focused ~250-line implementation is the smaller, more controllable choice. **Retain.**

### 6. JWT decode (Jwt.psm1) — KEEP
- ~60 lines: base64url-decode header/payload, parse claims, convert unix times. No
  signature validation is needed (the token is the user's own, captured live).
- `System.IdentityModel.Tokens.Jwt` is mature but drags in several `Microsoft.IdentityModel.*`
  DLLs for what is a ~15-line decode. Net negative here. **Retain.**

### 7. Config (Config.ps1) — KEEP
- Loads two JSON files, merges settings over code defaults. `Microsoft.Extensions.Configuration`
  is modern-.NET and heavy; `System.Configuration` is XML app.config, not our model.
  Custom code is small and clear, and now writes via Newtonsoft. **Retain.**

### 8. MVVM / logging / dialogs / notifications — KEEP
- The app wires a handful of named XAML elements from code; a full MVVM stack
  (Prism / CommunityToolkit.Mvvm) or logging framework (Serilog/NLog) would add
  complexity far exceeding the app's size. `MessageBox` + an inline status line cover
  dialogs/notifications. **Retain.**

## Recommendation
Adopt Newtonsoft.Json (done). Do not add further dependencies: the remaining custom code
is either built-in framework usage or small, stable, purpose-specific logic where a
library would increase size and coupling without a real maintainability or correctness
gain on this PS 5.1 / WPF portable app.
