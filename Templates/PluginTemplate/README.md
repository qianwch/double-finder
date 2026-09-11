# __NAME__

A Double Finder plugin (bundle id `__BUNDLE_ID__`).

```bash
./build.sh --install   # build → __NAME__.dfplugin → ~/Library/Application Support/Double Finder/Plugins
NC_PLUGIN_DIAG=1 "/Applications/Double Finder.app/Contents/MacOS/Double Finder"   # verify it loads
```

Edit `Sources/__NAME__/__NAME__.swift`. The plugin API and every extension point are
documented in the Double Finder plugin development guide (`docs/plugin-development.md`).
