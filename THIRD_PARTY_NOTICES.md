# Third-party notices

## Apple private-NCM Linux driver

`sc2/apple_mac_ncm.c` is adapted from the Linux CDC-NCM driver and retains the
copyright and dual-license notice embedded at the top of that source file. It
may be used under either GNU GPL version 2 or the 2-clause BSD license. The
prebuilt `sc2/apple_mac_ncm.ko` is supplied under the 2-clause BSD option.

The repository's MIT license does not replace that notice.

## Patched Dragon research binary

The patched Dragon binaries under `patched/` and
`experimental/jumping-sumo/`, and firmware-derived components in the bundled
SC3 resource packages, are supplied for interoperability research. They are
not covered by this repository's MIT license. Original copyrights and
trademarks remain with their respective owners. Their inclusion does not
establish a blanket redistribution license for third-party firmware.

## FFmpeg

FFmpeg is not stored in the source repository. The macOS release ZIP includes
an FFmpeg recovery decoder so users do not need Homebrew. FFmpeg builds may be licensed
under LGPL or GPL terms depending on how they were configured. Consult the
license information distributed with the FFmpeg build you use.
