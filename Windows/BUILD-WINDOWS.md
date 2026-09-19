# Build on Windows

Requirements: Windows 10 19041+ (Windows 11 recommended), Visual Studio 2022 with the .NET desktop workload and Windows App SDK support, or .NET 8 SDK plus the Windows App SDK build prerequisites.

```powershell
# from the repository root
./scripts/build.ps1
./scripts/test.ps1
python scripts/static-verify.py
./scripts/publish-win-x64.ps1
```

The published application is self-contained. The output directory is `artifacts/win-x64`.

For ARM64:

```powershell
./scripts/publish-win-arm64.ps1
```

The current project is unpackaged by design. `FileAssociationService` registers audio extensions per-user without requiring elevation. For an installer/MSIX, keep the published output and add your preferred packaging layer rather than coupling packaging to the player Core.

## Optional integrations

- Discord: create a Discord application and paste its numeric Application ID in Settings.
- Last.fm: enter API key, shared secret and a valid session key. Credentials are stored in Windows Credential Manager.
- ListenBrainz: enter the API server and user token. The token is stored in Windows Credential Manager.
- SpotiFLAC: point the app at a `spotiflac --web` server and provide its token, or use the locally detected `spotiflac` CLI to launch the TUI.
- Google Cast: Discover on the local network or enter a Cast receiver address. Local tracks are exposed through a temporary authenticated HTTP stream to the receiver.
