---
name: swift-expert
description: Use when writing or reviewing Swift / SwiftUI / PhotoKit code in this repo (the App Store / native photo-layer path). Consult references/latest-apis.md FIRST so you emit current APIs, not deprecated ones the training corpus is full of.
---

# swift-expert

The model confidently emits `NavigationView`, `ObservableObject`, and callback
PhotoKit because that is what most of the training corpus contains. SwiftUI
deprecates hard every WWDC. This skill exists for **one** reason: a maintained
map of what is current vs deprecated — a fact the model structurally cannot know
from weights alone.

## Rule

Before writing any Swift in this repo, read `references/latest-apis.md`. If your
first instinct is on the "deprecated" side of a row there, use the replacement.
That is the whole job. Everything below is a fact, not a preference.

## Scope for this repo

This app's only Swift future is the **native PhotoKit rewrite** (see `TODO.md` —
the App Store path). So the reference is SwiftUI + PhotoKit + Vision, because
that is where the lost osxphotos signals (`score`, `labels`, `fingerprint`) get
re-derived. Nothing here is generic app-building advice.

Deliberately NOT carried (per the "encode facts, not taste" rule): "prefer
native over bridging" style rules, Liquid Glass adoption guidance. This app is
native PhotoKit by construction and ships no chrome that needs glass.
