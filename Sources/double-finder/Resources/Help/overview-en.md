**Double Finder**

Double Finder is a dual-pane file manager for macOS, modeled on Total Commander.

**Panels**
Two independent panels sit side by side. The **active** panel has the focus; press **Tab** to switch sides. File operations (copy, move) go from the active panel to the other one. Press **⌘U** to swap the two panels.

**Navigating**
Double-click a folder or press **Return** to enter it; **Backspace** goes to the parent. Use the path bar or **⌘⇧G** (Go to Folder) to jump anywhere. **⌘L** focuses the command line; **⌘⇧T** opens a terminal in the current folder.

**Tabs**
Each panel has folder tabs: **⌘T** opens a new tab, **⌘W** closes it, click a tab to switch.

**Selecting & Filtering**
**⌘A** selects all. Type **+ / - / \*** to select, unselect, or invert by wildcard pattern. **⌘F** opens a quick filter to narrow the list as you type.

**File Operations (function keys)**
**F3** Quick Look · **F4** edit · **F5** copy · **F6** move · **F7** new folder · **F8** delete. **⌘⌫** moves to Trash instead of deleting permanently. When a name already exists at the destination you get an **Overwrite / Skip / Cancel** prompt. Rename a file by clicking its name or via the right-click menu.

**Archives**
Browse zip / tar / 7z / rar and more like folders — just press Return on them. **⌥F5** packs the selection into the other panel; **⌥F6** extracts an archive (with a progress sheet you can cancel; encrypted archives prompt for a password).

**Connect to Server**
**⌘K** opens one connection window for **SFTP**, **S3-compatible object storage** (AWS S3, MinIO, R2, Huawei OBS, …), and **SMB/NAS** — with live Bonjour discovery of servers on your network and a saved address book. Remote folders (and archives on SFTP) browse like local ones; S3 buckets/objects browse as folders/files. Copying to/from a server shows a progress bar (count-based for S3) and prompts Overwrite/Skip/Cancel on name conflicts.

**Editing remote files**
Press **F4** on an S3 or SFTP file to edit a local copy. After you save and switch back to Double Finder, it offers to upload your changes back to the server.

**Find & Sync**
**⌘⇧F** finds files by name or content. The Commands menu offers directory compare & synchronize.

**View**
**⌘1 / ⌘2 / ⌘3** switch Full / Brief / Thumbnail views. **⌘⇧D** toggles the directory tree; **⌘⇧B** flattens a subtree (branch view).

**Settings & Language**
Open Settings with **⌘,**. The General tab has a **Language** menu — Double Finder ships Chinese, Japanese, English, Korean, German, and French, switchable live.
