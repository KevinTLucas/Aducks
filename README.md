# Aducks

Look things up in Microsoft 365 / Entra ID (Azure AD) without writing code.
Pick what you want from a few dropdowns, click **Run query**, and read the answer
in a clear, expandable view.

**Is it safe?**
- Aducks only **reads**. It never changes anything in your directory.
- You see only what your own account is allowed to see.
- Your sign-in is kept in memory and is gone when you close the app.

Aducks signs you in through Microsoft's own **Graph Explorer** website, so there
is nothing to install and no app for IT to register. (A few lookups need
permissions an admin must approve; see [Troubleshooting](#troubleshooting).)

---

## Getting started

1. **Get Aducks.** On the GitHub page click **Code > Download ZIP**, or clone
   it with `git clone https://github.com/KevinTLucas/Aducks.git`.
   - **Downloaded the ZIP?** Before extracting, right-click the ZIP, choose
     **Properties**, tick **Unblock**, then **OK**. Windows marks downloaded
     files as "from the internet", and that blocks Aducks' JSON component from
     loading. Already extracted it? Run this in PowerShell inside the folder:
     `Get-ChildItem -Recurse | Unblock-File`
2. Open the **Aducks** folder and double-click **`Aducks.bat`**. A black window
   may flash for a moment; that's normal.
3. Click **Sign in with Microsoft**. The button changes to *Waiting for sign-in...*
4. A browser window opens at Graph Explorer and the Microsoft sign-in prompt
   appears. Sign in the way you normally do (password, MFA, etc.).
   - If the prompt doesn't appear within about 30 seconds, click **Sign in** on
     the Graph Explorer page yourself.
   - The browser opens with a fresh, empty profile each time. You won't see your
     bookmarks or extensions, and you'll need to sign in fully each time. That's
     expected.
5. The browser closes by itself and Aducks opens the query screen. You're in.

> **Want to look around first?** Click **Preview without signing in**. You appear
> as a sample user (John Smith at Contoso), and queries return made-up users:
> one record for lookups like *My profile* or *Manager*, and a list for the rest.
> You can try the results view, search, copy and Load more safely. Nothing is
> sent to Microsoft.

**What you need:** a Windows 10 or 11 PC and a Chromium-based browser (Microsoft
Edge, which every Windows PC has, or Chrome or Brave). No admin rights are
needed, and there is nothing to install. It runs on the Windows PowerShell and
.NET that are built into Windows.

> **Copying your Aducks folder to someone?** Your browser choice is saved in
> `config\settings.json` and goes with it. If you changed it from the default
> (Edge), check [Settings](#settings) on their PC.

---

## Running a query

The **Build a query** card asks up to four questions. Answer them from left to
right and top to bottom:

| Question | Example |
|---|---|
| **What are you looking for?** | *User* |
| **What do you want to see?** | *Direct group memberships* |
| **How do you want to find it?** | *UPN* (their sign-in name, e.g. `jsmith@contoso.com`) |
| **Value** | `jsmith@contoso.com` |

Then click **Run query**, or press **Enter** in the value box.

Questions that don't apply are hidden for you. For example, *Me > My profile*
doesn't need a value, so the value box goes away.

### Choosing which fields come back

**Return properties** lets you pick which fields you want back, such as a
person's display name, email or job title. The fields use Microsoft's own
names, like `displayName`, `mail` and `jobTitle`.

- **Default**: nothing is ticked, so Microsoft returns its standard set of fields.
- Tick fields one by one, or use the search box to find them.
- **Select all** ticks every field in the list, and the button then reads *All
  properties*.
- **Clear** unticks everything and goes back to Default.

> Some fields need extra permissions, or can't be requested when listing many
> users. Examples are `signInActivity`, `mailboxSettings` and `birthday`. If
> *Select all* gives an error, tick fewer fields.

### What's included

| Category | What you can see |
|---|---|
| **Me** | Your own profile and your group memberships |
| **User** | Profile and account status, recent audit-log changes, find by name, direct or all (nested) group memberships, licenses, manager, direct reports |
| **Group** | Details, members, owners (find the group by its **display name** or its Object ID) |
| **Delta** | Look up one user by Object ID through Microsoft's change-tracking ("delta") feed (listed as *Users Delata*) |

Some lookups run two steps for you behind the scenes. For example, *Group >
Members > Display name* first finds the group's ID from its name, then gets that
group's members. You just type the name. If several groups share that name,
the first match is used.

---

## Reading the results

The results header shows how many items came back, such as **50 item(s) (more
available)**. The results appear as a **tree**, fully expanded at first.

- Click the **▸** triangle next to a line to open or close it.
- **{12}** means "a record with 12 fields". **[3]** means "a list of 3 items".
- Colors help you scan. Field names are blue, text is green, numbers are
  orange, and `true` / `false` / `null` are purple.
- **Expand all (+)** and **Collapse all (–)** are at the top right of the results.

### Finding something

Type in **Search results** and press **Enter** (or click **Next**) to jump to
each match. **Shift+Enter** (or **Prev**) goes back. The counter shows where you
are, such as `3 / 17`.

### Copying

Right-click any line in the results to copy from it:

| To copy... | Right-click... | and choose |
|---|---|---|
| **One value** (e.g. an email address) | that value's line | **Copy value**. Text comes without quotes |
| **A whole record** (e.g. one user) | its `{12}` line | **Copy object (JSON)** |
| **A whole list** | its `[3]` line | **Copy list (JSON)** |
| **The record a value belongs to** | any field in it (e.g. `mail`) | **Copy parent object** |
| **Everything** | — | click **Copy** at the top right |

Objects and lists copy as tidy JSON that pastes cleanly into VS Code, Notepad, a
ticket, etc. You can also click a line and press **Ctrl+C**.

### More results

Large lists come back one page at a time. When there's more, a **Load more**
button appears. Each click adds the next page to the same list, so **Copy**
always gives you everything loaded so far.

---

## Your session

The pill at the top right shows a countdown until your sign-in expires, usually
60–90 minutes. Click it to see:

- your name, email and organization (shown as *Tenant*), plus your Tenant ID and Object ID (the IDs
  have copy buttons)
- when the session expires, and the permissions ("scopes") you have
- **Reauthenticate**: sign in again for a fresh session
- **Sign out**

When the session runs out you'll see *Token expired - please authenticate
again.* and return to the sign-in screen. Just sign in again.

---

## For advanced users

### Advanced mode

Tick **Advanced** in the query card to see the exact **Request URL** Aducks will
call.

- For normal queries you can edit the URL to run any Microsoft Graph *read*
  (GET) request.
- Changing a dropdown, the value or Return properties rebuilds the URL, and
  your edits are lost.
- Two-step lookups show each step in its own read-only box, in order. The last
  step is the one whose result you see, and **Return properties** apply to it.

### Copy token

**Copy token** (in the menu that opens when you click the pill) copies your access token for use in other
tools. Treat it like a password. Windows clipboard history may keep a copy.

### Adding or changing queries

Click **Edit queries** (top right of the query card). This opens the **Query
catalog**:

- **+ New**: start a blank query. **Clone**: copy the selected query (named
  "… (clone)") so you can tweak it without touching the original.
- **Delete query** removes the selected query.
- Edit the labels, the Graph URL, and the list of return properties people can
  pick from. **+ Add lookup** adds another "how do you want to find it" option.
  A lookup can also be *chained*, meaning two or more steps.
- Click **Save changes**. The dropdowns update straight away. **Close** without
  saving throws your edits away.

Queries are stored in `config\queries.json`, which you can share with teammates.

---

## Settings

Sign in (or click **Preview without signing in**). Click the pill at the top
right, then the **gear** icon. Click **Save changes** when you're done. Changes
apply the next time you sign in.

| Setting | What it does |
|---|---|
| **Browser** | Which browser opens for sign-in: `edge`, `chrome`, or the **full path** to another Chromium browser's `.exe`, e.g. `C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe`. Typing just `brave` opens Edge instead |
| **Sign-in button selector** | Leave this alone unless Microsoft changes the Graph Explorer page |
| **Login wait (seconds)** | How long Aducks waits for you to finish signing in (default 300) |

---

## Troubleshooting

| You see... | What it means / what to do |
|---|---|
| **Error 403**, often with *Insufficient privileges to complete the operation* | Your account doesn't have that permission yet. Open [Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer), sign in, open the **Modify permissions** tab, and consent to what the query needs (e.g. *User.Read.All*, *Group.Read.All*). Then click **Reauthenticate** in Aducks. Some permissions (e.g. *AuditLog.Read.All* for audit-log changes) need an admin to approve them |
| **Error 404** | Nothing exists with that UPN or ID. Check what you typed. For **Manager**, it can also mean the person has no manager set |
| **Error 400** | Graph didn't accept the request, often an Object ID that isn't a valid ID. If you used *Select all*, tick fewer fields |
| **No results.** / **0 items** | The query worked but nothing matched |
| **No match: step 1 returned nothing at '…'. Check the value you entered.** | In a two-step lookup, the first step found nothing (e.g. no group with that exact display name). Check the spelling |
| **Enter a value** / **Enter a URL** | Fill in the value box (or the Advanced URL) first |
| **Error loading more** | Fetching the next page failed. Try **Load more** again, or run the query again |
| **Graph rejected the token (401) - please authenticate again.** | Your sign-in is no longer valid. Sign in again |
| **Authentication failed: …Timed out after…** | Sign-in wasn't finished in time. Try again, or raise **Login wait** in Settings |
| **Authentication failed: …Could not reach the browser's remote-debugging endpoint…** | Your PC's policy may block the browser feature Aducks relies on. Try another browser in Settings. If every browser fails, Aducks can't sign in on this PC |
| **Authentication failed: …Browser path not found…** | The **Browser** setting points to a browser that isn't installed. Click **Preview without signing in**, open Settings (pill > gear), set **Browser** to `edge`, save, then **Sign out** and sign in again |
| **Authentication failed** mentioning the WebSocket or connection being closed | The browser was closed before sign-in finished. Just sign in again |
| **Double-clicking Aducks.bat does nothing** | PowerShell may be blocked on this PC. Run **`Aducks-debug.bat`** to see the startup error in a console window |

---

---

## License

Aducks is released under the [MIT License](LICENSE). It bundles
[Newtonsoft.Json](https://www.newtonsoft.com/json), also MIT licensed (see
[src/lib/Newtonsoft.Json.LICENSE.md](src/lib/Newtonsoft.Json.LICENSE.md)).

Aducks is an independent tool. It is not made or endorsed by Microsoft; it
uses the public Microsoft Graph API and Graph Explorer website.

*Technical details (how sign-in capture works, project layout, config file
format) are in [docs/DEVELOPER.md](docs/DEVELOPER.md).*
