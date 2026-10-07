# zget
> Zig version manager.

## Install

### Linux & macOS

```bash
curl -sSfL https://raw.githubusercontent.com/Satheeshsk369/zget/main/install.sh | sh
```
*Note: Make sure to add `~/.local/bin` to your shell profile `PATH` (such as `~/.bashrc`, `~/.zshrc`, or `~/.profile`).*

### Windows PowerShell

```powershell
powershell -NoProfile -Command "Invoke-Expression (Invoke-RestMethod 'https://raw.githubusercontent.com/Satheeshsk369/zget/main/install.ps1')"
```

## Commands

### Manage Zig versions

* **`install, i <TAG>`**: Install a Zig version. Skips download if already installed.
  * `--set`: Set this version as default after installation.
  * `--mirror=<name>`: Select an index mirror configured in `config.zon`.
  * `--url=<url>`: Specify a direct index JSON URL.
  * `-S`: Sync the index before installation.
* **`set, s <TAG>`**: Set the default Zig version.
* **`list, l [MIRROR]`**: List local installs, or remote versions if a mirror is specified (use `-S` to sync).
* **`current, c`**: Show the active Zig version and path.
* **`run, r <TAG> [ARGS...]`**: Run a specific installed Zig version with arguments.
* **`delete, d <TAG>`**: Delete an installed version.

### Maintain zget

* **`update, up [TAG]`**: Update the zget binary (optionally to a specific version).
* **`clean, cl`**: Delete cache and downloads.
* **`env, e`**: Print configuration and environment paths.
* **`version, v`**: Print the zget tool version.
* **`help, h`**: Print help message.

## Configuration

`zget` automatically generates a configuration file at `~/.config/zget/config.zon` (or `%APPDATA%\zget\config.zon` on Windows) on first run:

```zig
.{
    .mirrors = .{
        .{ .name = "ziglang", .url = "https://ziglang.org/download/index.json" },
        .{ .name = "mach", .url = "https://pkg.hexops.org/zig/index.json" },
        .{ .name = "my-custom-mirror", .url = "https://example.com/custom/index.json" },
    },
    .defaultMirror = "ziglang",
}
```

## Usage Examples

* Install a version:

  ```bash
  zget install 0.16.0
  ```

* Install and set as default immediately:

  ```bash
  zget install 0.16.0 --set
  ```

* Set an installed version as the default:

  ```bash
  zget set 0.16.0
  ```

* Switch between installed versions:

  ```bash
  zget set master
  zget set 0.16.0
  ```

* Run a specific version directly without setting it as default:

  ```bash
  zget run 0.16.0 version
  ```

* Install from a configured mirror:

  ```bash
  zget install 0.16.0 --mirror=mach
  ```

* Install using a custom index URL:

  ```bash
  zget install 0.16.0 --url="https://pkg.hexops.org/zig/index.json"
  ```

* Sync the index first and install latest `master`:

  ```bash
  zget -S install master
  ```

* List installed and remote versions:

  ```bash
  zget list                 # local versions
  zget list ziglang         # cached remote versions from ziglang mirror
  zget -S list mach         # sync mach index and list its versions
  ```

* Check active version and environment paths:

  ```bash
  zget current
  zget env
  ```

* Clean cached downloads:

  ```bash
  zget clean
  ```

* Self-update zget:

  ```bash
  zget update
  ```
