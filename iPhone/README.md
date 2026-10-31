# Cover Flow for iPhone

Open **CoverFlow-iPhone.xcodeproj**, select **CoverFlowiPhone**, choose your iPhone
or an iPhone simulator, and Run. For a physical phone, select your Apple Developer
team under **Signing & Capabilities** first. Requires iOS 17 or later.

The prepared Xcode-project ZIP includes the ONNX Runtime framework. Keep the entire
unzipped folder together: this project shares sources and resources with `../iPad`
and `../Sources`. It does not need package managers or a dependency download before
running. In a fresh Git checkout, run `../build-ios.command --project` to prepare it.

The iPhone interface has Collection, Up Next, Lyrics and Karaoke tabs, with
Visualizer and Settings under More. The compact player opens Now Playing, where
karaoke/vocal selection, lyrics, AirPlay and queue controls are available.

Features and native model requirements are documented in [the mobile guide](../iPad/README.md).
Raw PyTorch/Becruily checkpoints and desktop Demucs processing are not supported;
compatible native MDX/Core ML models and prepared stereo stems remain supported.
