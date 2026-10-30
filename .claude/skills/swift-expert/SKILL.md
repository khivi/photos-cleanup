---
name: swift-expert
description: Use when writing or reviewing Swift in this repo (the Swift package in Sources/). Consult references/latest-apis.md FIRST so you emit current APIs, not deprecated ones the training corpus is full of.
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

Swift here is the whole backend: the Swift package in `Sources/` (PhotoKit, Vision and
Foundation Models in `PhotosCleanupCore`, the SwiftUI app in `PhotosCleanupApp`).
The native SwiftUI + PhotoKit rewrite is not being pursued (see `TODO.md`); the
SwiftUI and PhotoKit rows stay in the reference in case that changes. Nothing
here is generic app-building advice.

Deliberately NOT carried (per the "encode facts, not taste" rule): "prefer
native over bridging" style rules, Liquid Glass adoption guidance. The Swift
here is headless and ships no chrome that needs glass.
