# Pinlume Product Definition

## Register

product

## Users

Pinlume is for macOS users who treat screenshots, pinned images, annotation, OCR, translation, and recording as frequent desktop actions. Typical work moves between browsers, development tools, design files, chat apps, and reference material. Users should be able to capture, pin, recognize, translate, record, or share content without being interrupted by unnecessary configuration or intermediate windows.

## Product Purpose

Pinlume is a native, lightweight, open-source screen tool for macOS. Starting from a keyboard shortcut, it keeps capture, annotation, copy, save, pinning, OCR, translation, recording, and upload on the shortest practical path.

Success means fast launch and shortcut response; stable selection, pin, transparent-annotation, and presentation-drawing placement; common actions completed in place; and predictable saving, focus, permission, update, and local-persistence behavior.

## Scope

- **Capture and pinning:** Region capture, window snapping, pinning from the clipboard, floating pins, thumbnails, and re-editing.
- **Annotation and presentation:** Everyday drawing and redaction tools, transparent annotation, and presentation drawing for immediate explanation and live demos.
- **Understanding and conversion:** Apple Vision OCR, screenshot translation, selected-text translation, and a multilingual interface.
- **Recording and output:** Region or full-screen recording, MP4/GIF export, trimming, and user-initiated uploads.
- **Local first:** User content stays on the Mac by default. Translation, uploads, and updates have explicit entry points and boundaries.

## Brand Personality

Native, lightweight, fluid, and dependable. The interface serves the task and favors familiar macOS controls and keyboard interaction. It does not manufacture a sense of sophistication through decoration, excessive hierarchy, or animation.

## Anti-references

- Do not become an all-in-one workspace or a heavyweight image editor.
- Do not replace standard system interaction with flashy animation, repeated cards, glassmorphism, or invented controls.
- Do not hide failures or trade focus stability for superficial usability through magic delays or hard-coded offsets.
- Do not put screenshots, recordings, OCR, translation, or clipboard text into diagnostic logs.
- Do not upload content or send it to a third-party translation provider without an explicit user action.

## Design Principles

1. **Finish work in place:** Recognition, translation, annotation, and pinning should preserve the user's spatial relationship with the selected content whenever possible.
2. **Keep paths short and state clear:** Capture, text selection, annotation, dragging, recording, and translation must not fight for the same input. The active state must be visible.
3. **Favor familiar behavior:** Copy, select all, edit, speech, language selection, and permission interactions should follow macOS conventions.
4. **Local first, network under control:** Translation, upload, and update actions need clear purposes and boundaries. Google Translate must honor the selected provider and the **Allow sending text to Google Translate** setting.
5. **Fail without losing work:** If OCR, translation, upload, or update fails, preserve the source image, source text, and current work. Do not produce an empty result or discard edits.
6. **Maintain publicly without overpromising:** Automatic updates, the privacy policy, release notes, and Issue feedback must describe capabilities truthfully. Do not advertise unsupported behavior in advance.

## Accessibility and Inclusion

- Every button has an accessible name and keyboard operation.
- Text selection uses the system selection highlight; color is never the only state indicator.
- Respect the system Reduce Motion setting and avoid decorative animation.
- Translation, speech, and shortcuts are explained in Settings. Accessibility permission is requested only for features that need it, such as reading selected text in other apps or auto-scroll.
