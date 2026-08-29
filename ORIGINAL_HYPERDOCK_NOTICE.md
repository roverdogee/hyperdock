# Original HyperDock provenance and asset boundary

This project is an independent Apple Silicon implementation developed through reverse
engineering, visual comparison, and behavioural observation of the discontinued
HyperDock 1.8 preference pane and helper application. No original HyperDock source code
is included.

Local development builds may use unmodified close-button images extracted from a copy
of HyperDock lawfully obtained by the user. Those optional files live under
`Sources/HyperDock/Resources/OriginalHyperDock/`, are excluded by `.gitignore`, and are
not distributed by this repository. A code-native fallback is used when they are absent.

Original HyperDock copyright © 2018 Christian Baumgart. All rights reserved. The
HyperDock name and original artwork are not covered by this repository's MIT license.
The MIT license applies only to the independently written source code and original work
created for this implementation.
