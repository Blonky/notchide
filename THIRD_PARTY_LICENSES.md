# Third-party licenses & attribution

notchide is MIT-licensed (see [LICENSE](LICENSE)). It builds on, and was informed by, the work
of others. This document records the dependencies notchide ships or plans to ship, and the prior
art it studied but did not fork.

If you believe an attribution here is inaccurate or incomplete, please open an issue — getting
this right matters to us.

---

## Dependencies notchide uses

### DynamicNotchKit — MIT

- **Author:** MrKai77
- **License:** MIT
- **Repository:** https://github.com/MrKai77/DynamicNotchKit
- **Role:** the notch substrate. notchide's GUI (`app/` package) depends on DynamicNotchKit for
  the `NSPanel` geometry, the animatable notch-shape morph, and the floating-pill fallback used
  on external monitors and non-notch Macs.

> The MIT License requires that DynamicNotchKit's copyright notice and permission notice be
> included in distributions. The full upstream `LICENSE` text is bundled with the built app and
> reproduced with the resolved dependency graph; refer to the upstream repository for the
> canonical text.

---

## Planned dependencies (diff highlighting)

The read-only, syntax-highlighted git diff in the review console is planned to use the following
libraries. These are stable, independently-versioned components used **only to highlight** a
diff — notchide is **not** a code editor and does not embed a pre-1.0 editor.

### Neon — BSD-3-Clause

- **License:** BSD-3-Clause
- **Repository:** https://github.com/ChimeHQ/Neon
- **Role:** incremental syntax-highlighting engine driving the diff view's coloring.

### SwiftTreeSitter — BSD-3-Clause (bindings)

- **License:** BSD-3-Clause (Swift bindings). Note: the underlying **tree-sitter** C library and
  individual grammar files carry their own licenses (commonly MIT / Apache-2.0); those are
  honored per-grammar.
- **Repository:** https://github.com/ChimeHQ/SwiftTreeSitter
- **Role:** Swift bindings to tree-sitter, providing the parse trees Neon highlights from.

### CodeEditLanguages — MIT

- **Author:** the CodeEdit project (CodeEditApp)
- **License:** MIT
- **Repository:** https://github.com/CodeEditApp/CodeEditLanguages
- **Role:** packaged tree-sitter language grammars, so the diff view can highlight many
  languages without vendoring grammars by hand.

> When these dependencies are added to the `app/` package, their license texts ship with the
> resolved dependency graph and this section will be updated to reflect the exact pinned
> versions.

---

## Prior art — studied, not forked

notchide exists in a lively "notch tools" ecosystem. The projects below shaped our thinking. We
**studied** them for ideas and interaction patterns; we did **not** fork, copy, or incorporate
their code. They are listed here out of respect and for transparency, with their licenses noted.

| Project        | Author  | License        | Relationship to notchide                                            |
| -------------- | ------- | -------------- | ------------------------------------------------------------------- |
| klo-local      | elvniv  | Apache-2.0     | Studied — approach to local agent status in the notch.              |
| NotchFlow      | —       | MIT            | Studied — worktree/branch surfacing (informs the v0.3 direction).   |
| CodeIsland     | —       | MIT            | Studied — coding-context presentation in a notch surface.           |
| Claude Island  | —       | Apache-2.0     | Studied — Claude-session status in the notch.                       |
| boring.notch   | —       | CC-BY-NC-ND    | **Study only.** Its license is non-commercial, no-derivatives; no code was used or adapted. |

**Note on boring.notch:** its CC-BY-NC-ND license permits neither derivative works nor
commercial use. notchide contains none of its code and is not derived from it; it is listed
solely to acknowledge prior art we looked at.

None of the projects above are dependencies of notchide. The only third-party code notchide
ships is listed in the sections above.
