# Changelog

## 1.0.7

- Prepare missing Apple Translation language packs before starting translation, and keep the screenshot overlay from blocking the system download sheet.
- Make translation progress and detailed errors use separate status areas; Esc now closes the translation window through its normal cancellation path.
- Render screenshot translation text at a true Retina-aware 8 pt minimum and use fast OCR only for the screenshot-translation path.
- Refresh the permission-onboarding guide artwork.

## 1.0.6

- Keep selected-text translation optional: request Accessibility once, synchronize the setting with the real permission result, and preserve clipboard translation when permission is declined.
- Allow standard captures to copy the complete annotated selection while a drawing tool is active, and fully finish the capture after a successful save.
- Make transparent annotation Copy, Save, and Pin use the current transparent content; add working Command-C and Command-S routes while preserving the empty-content no-op.
- Remove full-screen overlay input before showing save panels, restoring the session only after cancellation or failure.

## 1.0.5

- Keep compact Pins fully opaque, ignore opacity adjustments while compact, and restore each Pin's normal opacity when expanded.

## 1.0.4

- Unify configurable toolbar shortcuts across standard captures, transparent annotation, pins, selectable OCR, and screen translation.
- Make `F` pin completed OCR and screen translation results even when text selection owns keyboard focus.
- Keep Censor tooltips concise and align transparent annotation's Cancel / Save / Copy / Pin ordering with standard capture.

## 1.0.3

- Give both built-in profiles the Graphite Blue toolbar palette instead of leaving Professional as Custom.
- Migrate existing built-in Professional profiles to that palette without changing user-created Custom profiles.

## 1.0.2

- Fix built-in profile migration so opening or using a preset does not create a duplicate profile without an actual user edit.
- Keep Slim and Professional on the same shortcut baseline, including transparent annotation and presentation drawing.
- Default Marker to the ordinary 3 px circular cursor; Smart Marker remains available as an opt-in setting.
