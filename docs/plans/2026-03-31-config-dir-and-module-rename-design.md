# Design: Config Directory Resolution & Module Rename

**Issue:** #5 — Support configurable config directory via environment variable
**Date:** 2026-03-31

## Summary

Two related changes:

1. Add `FRESHBOOKS_HOME` env var support and platform-native config directory resolution for new installs
2. Rename the `FB` Ruby module to `FreshBooks::CLI` throughout

## 1. Config Directory Resolution

`Auth.data_dir` currently hardcodes `~/.fb`. The new implementation resolves the directory via a private `resolve_data_dir` helper using this lookup order:

1. `FRESHBOOKS_HOME` env var — explicit user override
2. `~/.fb` if it exists — legacy path, keeps existing users unaffected
3. Platform-native default for new installs:
   - **macOS** (`RUBY_PLATFORM =~ /darwin/`): `~/Library/Application Support/freshbooks`
   - **Linux/other**: `$XDG_CONFIG_HOME/freshbooks` → `~/.config/freshbooks`

```ruby
def data_dir
  return @data_dir unless @data_dir.nil?
  resolve_data_dir
end

private

def resolve_data_dir
  return ENV["FRESHBOOKS_HOME"] if ENV["FRESHBOOKS_HOME"]
  legacy = File.join(Dir.home, ".fb")
  return legacy if File.exist?(legacy)
  if RUBY_PLATFORM =~ /darwin/
    File.join(Dir.home, "Library", "Application Support", "freshbooks")
  else
    xdg_base = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
    File.join(xdg_base, "freshbooks")
  end
end
```

### Setter cleanup

`data_dir=` stays. Setting it to `nil` resets to auto-resolution (getter no longer uses `||=`). spec_helper updated to use the public setter instead of `instance_variable_set`.

## 2. Module Rename

| Old | New |
|-----|-----|
| `FB::Auth` | `FreshBooks::CLI::Auth` |
| `FB::Api` | `FreshBooks::CLI::Api` |
| `FB::Spinner` | `FreshBooks::CLI::Spinner` |
| `FB::Cli` | `FreshBooks::CLI::Commands` |
| `VERSION` (in `FB`) | `FreshBooks::CLI::VERSION` |
| `lib/fb.rb` | `lib/freshbooks.rb` |
| `lib/fb/*.rb` | `lib/freshbooks/*.rb` |
| `require "fb"` | `require "freshbooks"` |

The gemspec (`fb.gemspec`) also needs updating:
- `require_relative "lib/fb/version"` → `require_relative "lib/freshbooks/version"`
- `FB::VERSION` → `FreshBooks::CLI::VERSION`

The CLI binary (`fb`) and gem name (`freshbooks-cli`) are unchanged.

## 3. Testing

New tests for `resolve_data_dir`:

- Returns `FRESHBOOKS_HOME` when set
- Returns `~/.fb` when it exists (legacy)
- Returns `~/Library/Application Support/freshbooks` on macOS when no legacy path
- Returns `$XDG_CONFIG_HOME/freshbooks` on Linux when set and no legacy path
- Returns `~/.config/freshbooks` on Linux when `XDG_CONFIG_HOME` unset and no legacy path
- `data_dir = nil` resets to auto-resolution

All existing tests: update `FB::` references to `FreshBooks::CLI::`.

## 4. Documentation

- `AGENTS.md`: update module names, `data_dir` behaviour, env var name
- `README`: update any references to `~/.fb`, add `FRESHBOOKS_HOME` to configuration section
