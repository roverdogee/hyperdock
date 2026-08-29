# Original HyperDock provenance and asset boundary

This project is an independent Apple Silicon implementation developed through reverse
engineering, visual comparison, and behavioural observation of the discontinued
HyperDock 1.8 preference pane and helper application. No original HyperDock source code
is included.

The repository includes artwork extracted from HyperDock 1.8 under
`Sources/HyperDock/Resources/OriginalHyperDock/` for preservation and compatibility
with the four legacy appearance themes. The current implementation actively uses only
the original close-button images in those themes; the native Liquid Glass theme uses no
original HyperDock image resources. A code-native fallback remains available when the
close-button files are absent.

All files in that resource directory are original HyperDock artwork. They are provided
separately from the MIT-licensed source code, without modification to their ownership or
copyright status. They may not be assumed to carry the MIT license or any permission for
reuse outside the rights granted by their copyright owner. See the `COPYRIGHT.txt` file
inside that directory.

Original HyperDock copyright © 2018 Christian Baumgart. All rights reserved. The
HyperDock name and original artwork are not covered by this repository's MIT license.
The MIT license applies only to the independently written source code and original work
created for this implementation. Inclusion does not imply endorsement by or affiliation
with the original author.
